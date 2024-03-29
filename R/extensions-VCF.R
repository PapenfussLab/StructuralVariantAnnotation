#' @noRd
.dispatchPerAllele_CollapsedVCF <- function(FUN, x, singleAltOnly) {
    alt <- alt(x)
    flat <- BiocGenerics::unlist(alt, use.names=FALSE)
    res <- FUN(rep(ref(x), S4Vectors::elementNROWS(alt(x))), flat)
    lst <- relist(res, alt)
    if (singleAltOnly)
        all(lst) & S4Vectors::elementNROWS(lst) == 1
    else
        any(lst)
}
#' @noRd
.dispatchPerAllele_ExpandedVCF <- function(FUN, x) {
    alt <- alt(x)
    flat <- BiocGenerics::unlist(alt, use.names=FALSE)
    res <- FUN(rep(ref(x), S4Vectors::elementNROWS(alt(x))), flat)
    res
}

#' Determining whether the variant is a symbolic allele.
#' @details The function takes a VCF object as input, and returns a logical
#' value for each row, determining whether the variant is a symbolic allele.
#' @param x A VCF object.
#' @param ... Internal parameters.
#' @return A logical list of which the length is the same with the input object.
#' @examples
#' vcf.file <- system.file("extdata", "gridss.vcf", package = "StructuralVariantAnnotation")
#' vcf <- VariantAnnotation::readVcf(vcf.file, "hg19")
#' isSymbolic(vcf)
#' @export
setGeneric("isSymbolic", signature="x",
           function(x, ...)
               standardGeneric("isSymbolic")
)

#' @describeIn isSymbolic Determining whether a CollapsedVCF object is a symbolic 
#' allele. Only single ALT values are accepted.
#' @param singleAltOnly Whether only single ALT values are accepted. Default is
#' set to TRUE.
setMethod("isSymbolic", "CollapsedVCF",
          function(x, ..., singleAltOnly=TRUE)
              .dispatchPerAllele_CollapsedVCF(.isSymbolic, x, singleAltOnly)
)
#' @describeIn isSymbolic Determining whether a ExpandedVCF object is a symbolic 
#' allele
#' 
setMethod("isSymbolic", "ExpandedVCF",
          function(x, ...)
              .dispatchPerAllele_ExpandedVCF(.isSymbolic, x)
)
#' Determining whether the variant is a symbolic allele.
#' @param r Reference vector.
#' @param a ALT vector.
#' @return A logical list of which the length is the same with the input object.
#' @noRd
.isSymbolic <- function(r, a) {
    result <- grepl("<", a, fixed=TRUE) |
        grepl("[", a, fixed=TRUE) |
        grepl("]", a, fixed=TRUE) |
    	grepl(".", a, fixed=TRUE)
    return(result)
}

#' Determining whether the variant is a structural variant
#' @details The function takes a VCF object as input, and returns a logical
#' value for each row, determining whether the variant is a structural variant.
#' @param x A VCF object.
#' @param ... Internal parameters.
#' @return A logical list of which the length is the same with the input object.
#' @examples
#' vcf.file <- system.file("extdata", "gridss.vcf", package = "StructuralVariantAnnotation")
#' vcf <- VariantAnnotation::readVcf(vcf.file, "hg19")
#' isStructural(vcf)
#' @export
setGeneric("isStructural", signature="x",
           function(x, ...)
               standardGeneric("isStructural")
)
#' @describeIn isStructural
#' Determining whether a CollapsedVCF object is a 
#' strucrual variant. Only single ALT values are accepted.
#' @param singleAltOnly Whether only single ALT values are accepted. Default is
#' set to TRUE.
setMethod("isStructural", "CollapsedVCF",
          function(x, ..., singleAltOnly=TRUE)
              .dispatchPerAllele_CollapsedVCF(.isStructural, x, singleAltOnly)
)
#' @describeIn isStructural Determining whether a ExpandedVCF object is a 
#' structural variant.
setMethod("isStructural", "ExpandedVCF",
          function(x, ...)
              .dispatchPerAllele_ExpandedVCF(.isStructural, x)
)
#' @noRd
.isStructural <- function(ref, alt) {
	lengthDiff <- S4Vectors::elementNROWS(ref) != IRanges::nchar(alt)
	if (is(alt, "DNAStringSet")) {
		# don't break if there are no symbolic alleles in the VCF
		return(lengthDiff)
	}
	return(as.logical(
		# exclude no-call sites
		!is.na(alt) & alt != "<NON_REF>" &
			(lengthDiff | .isSymbolic(ref, alt))))
}


#' Returns the structural variant length of the first allele
#'
#' @param vcf VCF object
#' @return Structural variant lengths of the first allele.
#' @noRd
.svLen <- function(vcf) {
	assertthat::assert_that(.hasSingleAllelePerRecord(vcf))
	r <- ref(vcf)
	a <- elementExtract(alt(vcf))
	result <- ifelse(!isStructural(vcf), 0,
					 .replaceNa(elementExtract(info(vcf)$SVLEN),
					 		   .replaceNa(elementExtract(info(vcf)$END) - start(SummarizedExperiment::rowRanges(vcf)),
					 		   		   ifelse(isSymbolic(vcf), NA_integer_, IRanges::nchar(a) - IRanges::nchar(r)))))
	return(result)
}

#' @noRd
.hasSingleAllelePerRecord <- function(vcf) {
	assertthat::assert_that(is(vcf, "VCF"))
	all(S4Vectors::elementNROWS(alt(vcf)) == 1)
}

#' @describeIn isStructural Determining whether a VCF object is a structural
#' variant.
setMethod("isStructural", "VCF",
		  function(x, ...)
		  	.dispatchPerAllele_ExpandedVCF(.isStructural, x)
)


#' Extracting the structural variants as a GRanges.
#'
#' @details
#' Structural variants are converted to breakend notation.
#' Due to ambiguities in the VCF specifications, structural variants
#' with multiple alt alleles are not supported.
#' The CIPOS tag describes the uncertainty interval around the position
#' of the breakend. See Section 5.4.8 of
#' \url{https://samtools.github.io/hts-specs/VCFv4.3.pdf} for details of CIPOS.
#' If HOMLEN or HOMSEQ is defined without CIPOS, it is assumed that
#' the variant position is left aligned.
#' A breakend on the '+' strand indicates a break immediately after the given
#' position, to the left of which is the DNA segment involved in the breakpoint.
#' The '-' strand indicates a break immediately before the given position,
#' rightwards of which is the DNA segment involved in the breakpoint.
#' Unpaired variants are removed at this stage.
#' @param x A VCF object
#' @param ... Parameters of \code{.breakpointRanges()}. See below.
#' @return A GRanges object of SVs.
#' @examples
#' vcf.file <- system.file("extdata", "vcf4.2.example.sv.vcf",
#'                          package = "StructuralVariantAnnotation")
#' vcf <- VariantAnnotation::readVcf(vcf.file, "hg19")
#' breakpointRanges(vcf)
#' breakpointRanges(vcf, nominalPosition=TRUE)
#' @export
setGeneric("breakpointRanges", signature="x",
		   function(x, ...)
		   	standardGeneric("breakpointRanges")
)
#' @describeIn breakpointRanges Extracting structural variants as GRanges.
setMethod("breakpointRanges", "VCF",
		  function(x, ...)
		  	.breakpointRanges(x, ...)
)

#' .breakpointRanges() is an internal function for extracting structural 
#' variants as GRanges.
#' @param vcf A VCF object.
#' @param nominalPosition Determines whether to call the variant at the
#' nominal VCF position, or to call the confidence interval (incorporating
#' any homology present). Default value is set to FALSE, where the interval is
#' called based on the CIPOS tag. When set to TRUE, the ranges field contains
#' the nominal variant position only.
#' @param placeholderName Variant name prefix to assign to unnamed variants.
#' @param suffix The suffix to append to variant names.
#' @param info_columns VCF INFO columns to include in the GRanges object.
#' @param unpartneredBreakends Determining whether to report unpartnered 
#' breakends. Default is set to FALSE.
#' @param inferMissingBreakends Infer missing breakend records from ALT field of records without matching partners
#' @param ignoreUnknownSymbolicAlleles Ignore unknown symbolic alleles.
#' StructuralVariantAnnotation currently handles INS, INV, DEL, DUP as well as
#' the VCF specifications non-compliant RPL, TRA symbolic alleles.
#' @rdname breakpointRanges
.breakpointRanges <- function(
	vcf,
	nominalPosition=FALSE,
	placeholderName="svrecord", suffix="_bp",
	info_columns=NULL,
	unpartneredBreakends=FALSE,
	inferMissingBreakends=FALSE,
	ignoreUnknownSymbolicAlleles=FALSE) {
	vcf <- vcf[isStructural(vcf),]
	assertthat::assert_that(.hasSingleAllelePerRecord(vcf))
	# VariantAnnotation bug: SV row names are not unique
	# ensure names are defined
	if (any(duplicated(row.names(vcf)))) {
		warning("Found ", sum(duplicated(row.names(vcf))), " duplicate row names (duplicates renamed).")
	}
	if (is.null(row.names(vcf))) {
		row.names(vcf) <- paste0(placeholderName, seq_along(vcf), row.names(vcf))
	} else if (any(is.na(row.names(vcf)) | duplicated(row.names(vcf)))) {
		row.names(vcf) <- ifelse(is.na(row.names(vcf)) | duplicated(row.names(vcf)), paste0(placeholderName, seq_along(vcf)), row.names(vcf))
	}
	assertthat::assert_that(!is.null(row.names(vcf)))
	assertthat::assert_that(assertthat::noNA(row.names(vcf)))
	assertthat::assert_that(!any(duplicated(row.names(vcf))))
	gr <- SummarizedExperiment::rowRanges(vcf)
	gr$REF <- as.character(ref(vcf))
	gr$ALT <- as.character(elementExtract(alt(vcf), 1))
	gr$sourceId <- names(vcf)
	gr$partner <- rep(NA_character_, length(gr))
	gr$svtype <- stringr::str_match(c("HACK", gr$ALT), "<(.*)>")[,2][-1] |> # HACK ensures that [,2] exists even for zero record vcfs
		.replaceNa(elementExtract(info(vcf)$SVTYPE) |> .replaceNull(rep(NA_character_, length(gr))))
	gr$svtype = ifelse(stringr::str_detect(gr$ALT, stringr::fixed("[")) | stringr::str_detect(gr$ALT, stringr::fixed("]")), "BND", gr$svtype)
	gr$svtype = ifelse(stringr::str_starts(gr$ALT, stringr::fixed(".")) | stringr::str_ends(  gr$ALT, stringr::fixed(".")), "BND", gr$svtype)
	# use the root type
	gr$svtype <- stringr::str_extract(gr$svtype, "^[^:]+")
	gr$svLen <- .svLen(vcf)
	gr$insSeq <- rep(NA_character_, length(gr))
	gr$insLen <- rep(0, length(gr))
	gr$cistartoffset <- rep(0, length(gr))
	gr$ciwidth <- rep(0, length(gr))
	gr$event <- info(vcf)$EVENT |> .replaceNull(rep(NA_character_, length(gr)))
	
	for (col in info_columns) {
		S4Vectors::mcols(gr)[[col]] <- info(vcf)[[col]]
	}
	if (!is.null(info(vcf)$HOMSEQ)) {
		seq <- elementExtract(info(vcf)$HOMSEQ, 1)
		gr$ciwidth <- ifelse(is.na(seq) | seq == ".", gr$ciwidth, nchar(seq))
	}
	if (!is.null(info(vcf)$HOMLEN)) {
		gr$ciwidth <- .replaceNa(elementExtract(info(vcf)$HOMLEN, 1), gr$ciwidth)
	}
	# have not yet factored in imprecise variant calling into ciwidth - just microhomology
	gr$HOMLEN <- gr$ciwidth
	
	if (!is.null(info(vcf)$CIPOS)) {
		# VCFv4.4 uses 2*A
		#.expectMetadataInfo(vcf, "CIPOS", 2, header.Type.Integer)
		cistartoffset <- elementExtract(info(vcf)$CIPOS, 1)
		ciendoffset <- elementExtract(info(vcf)$CIPOS, 2)
		ciwidth <- ciendoffset - cistartoffset
		gr$cistartoffset <- .replaceNa(cistartoffset, gr$cistartoffset)
		gr$ciwidth <- .replaceNa(ciwidth, gr$ciwidth)
	}
	gr$processed <- rep(FALSE, length(gr))
	outgr <- gr[FALSE,]
	# Symbolic alleles known to not be structural variant alleles
	rows <- !gr$processed & !is.na(gr$svtype) & gr$svtype %in% c(
		"CNV",
		"*",
		"NON_REF",
		# IUPAC ambiguity codes
		"U","R","Y","S","W","K","M","B","D","H","V","N")
	gr$processed[rows] <- TRUE
	# VCFv4.4 SVCLAIM field. Abundance claims are explicitly not breakpoint claims
	if (!is.null(info(vcf)$SVCLAIM)) {
		rows <- !gr$processed & as.character(info(vcf)$SVCLAIM) == "D"
		gr$processed[rows] <- TRUE
	}
	# Indels
	rows <- !gr$processed & !isSymbolic(vcf) & stringr::str_length(gr$ALT) > 0
	if (any(rows)) {
		cgr <- gr[rows,]
		gr$processed[rows] <- TRUE
		if (!unpartneredBreakends) {
			commonPrefixLength <- .pairwiseLCPrefix(cgr$REF, cgr$ALT, ignore.case=TRUE)
			cgr$svLen <- nchar(cgr$ALT) - nchar(cgr$REF)
			cgr$insSeq <- Biostrings::subseq(cgr$ALT, start=commonPrefixLength + 1)
			cgr$insLen <- nchar(cgr$insSeq)
			start(cgr) <- start(cgr) - 1 + commonPrefixLength
			width(cgr) <- 1
			strand(cgr) <- "+"
			mategr <- cgr
			strand(mategr) <- "-"
			ranges(mategr) <- IRanges::IRanges(start=start(cgr) + nchar(cgr$REF) - commonPrefixLength + 1, width=1)
			
			names(mategr) <- paste0(names(cgr), suffix, 2)
			names(cgr) <- paste0(names(cgr), suffix, 1)
			cgr$partner <- names(mategr)
			mategr$partner <- names(cgr)
			outgr <- c(outgr, cgr, mategr)
		}
		cgr <- NULL
		mategr <- NULL
	}
	rows <- !gr$processed & !is.na(gr$svtype) & gr$svtype %in% c("DEL", "INS", "DUP", "RPL", "UNK")
	if (any(rows)) {
		cgr <- gr[rows,]
		gr$processed[rows] <- TRUE
		if (!unpartneredBreakends) {
			cvcf <- vcf[rows,]
			#assertthat::assert_that(!any(cgr$svtype == "DEL" & cgr$svLen > 0))
			#assertthat::assert_that(!any(cgr$svtype == "INS" & cgr$svLen < 0))
			dup <- cgr$svtype == "DUP"
			del <- cgr$svtype == "DEL"
			ins <- cgr$svtype == "INS"
			ukn <- cgr$svtype == "UNK"
			
			strand(cgr) <- "+"
			width(cgr) <- 1
			cgr$insLen <- ifelse(ins, abs(cgr$svLen), 0)
			if (!is.null(info(cvcf)$NTLEN)) {
				#pindel RPL is a deletion with NTLEN bases inserted
				cgr$insLen <- .replaceNa(elementExtract(info(cvcf)$NTLEN), cgr$insLen)
			}
			mategr <- cgr
			strand(mategr) <- "-"
			# use SVLEN then fall back to END
			end <- (start(cgr) + ifelse(ins, 0, abs(cgr$svLen))) |> .replaceNa(elementExtract(info(cvcf)$END, 1))
			if (any(is.na(end))) {
				stop(paste("Variant of undefined length: ", paste(names(cgr)[is.na(end),], collapse=", ")))
			}
			ranges(mategr) <- IRanges::IRanges(start=end + ifelse(dup | ukn, 0, 1), width=1)
			ranges(cgr) <- IRanges::IRanges(start=start(cgr) + ifelse(dup | ukn, 1, 0), width=1, names=names(cgr))
			
			end_ci = .calc_right_confidence_interval(
				cgr$cistartoffset,
				cgr$ciwidth,
				cgr$svtype,
				cgr$svLen,
				info(cvcf)$CIEND,
				info(cvcf)$CILEN)
			mategr$cistartoffset <- end_ci$cistartoffset
			mategr$ciwidth <- end_ci$ciwidth
			
			strand(cgr)[dup] <- "-"
			strand(mategr)[dup] <- "+"
			
			strand(cgr)[ukn] <- "*"
			strand(mategr)[ukn] <- "*"
			
			names(mategr) <- paste0(names(cgr), suffix, 2)
			names(cgr) <- paste0(names(cgr), suffix, 1)
			cgr$partner <- names(mategr)
			mategr$partner <- names(cgr)
			outgr <- c(outgr, cgr, mategr)
		}
		cgr <- NULL
		mategr <- NULL
	}
	rows <- !gr$processed & !is.na(gr$svtype) & gr$svtype %in% c("INV")
	if (any(rows)) {
		cgr1 <- gr[rows,]
		gr$processed[rows] <- TRUE
		if (!unpartneredBreakends) {
			cvcf <- vcf[rows,]
			width(cgr1) <- 1
			end <- (start(cgr1) + abs(cgr1$svLen)) |> .replaceNa(elementExtract(info(cvcf)$END, 1))
			if (any(is.na(end))) {
				stop(paste("Variant of undefined length: ", paste(names(cgr1)[is.na(end),], collapse=", ")))
			}
			hasPlusBreakend <- rep(TRUE, length(cgr1))
			hasMinusBreakend <- rep(TRUE, length(cgr1))
			if (!is.null(info(vcf)$INV3)) {
				hasMinusBreakend <- !info(vcf)$INV3[rows]
			}
			if (!is.null(info(vcf)$INV5)) {
				hasPlusBreakend <- !info(vcf)$INV5[rows]
			}
			
			cgr2 <- cgr1
			end_ci = .calc_right_confidence_interval(
				cgr1$cistartoffset,
				cgr1$ciwidth,
				cgr1$svtype,
				cgr1$svLen,
				info(cvcf)$CIEND,
				info(cvcf)$CILEN)
			cgr2$cistartoffset <- end_ci$cistartoffset
			cgr2$ciwidth <- end_ci$ciwidth
			cgr3 <- cgr1
			cgr4 <- cgr2
			
			ranges(cgr2) <- IRanges::IRanges(start=end + 1, width=1)
			ranges(cgr3) <- IRanges::IRanges(start=start(cgr1), width=1)
			ranges(cgr4) <- IRanges::IRanges(start=end, width=1)
			ranges(cgr1) <- IRanges::IRanges(start=start(cgr1) + 1, width=1, names=names(cgr1))
			strand(cgr1) <- "-"
			strand(cgr2) <- "-"
			strand(cgr3) <- "+"
			strand(cgr4) <- "+"
			
			names(cgr4) <- paste0(names(cgr1), suffix, 4)
			names(cgr3) <- paste0(names(cgr1), suffix, 3)
			names(cgr2) <- paste0(names(cgr1), suffix, 2)
			names(cgr1) <- paste0(names(cgr1), suffix, 1)
			cgr1$partner <- names(cgr2)
			cgr2$partner <- names(cgr1)
			cgr3$partner <- names(cgr4)
			cgr4$partner <- names(cgr3)
			
			outgr <- c(outgr, cgr1[hasMinusBreakend], cgr2[hasMinusBreakend], cgr3[hasPlusBreakend], cgr4[hasPlusBreakend])
		}
		cgr1 <- NULL
		cgr2 <- NULL
		cgr3 <- NULL
		cgr4 <- NULL
	}
	rows <- !gr$processed & !is.na(gr$svtype) & gr$svtype %in% c("BND") & (stringr::str_detect(gr$ALT, stringr::fixed("[")) | stringr::str_detect(gr$ALT, stringr::fixed("]")))
	if (any(rows)) {
		cgr <- gr[rows,]
		gr$processed[rows] <- TRUE
		if (!unpartneredBreakends) {
			cvcf <- vcf[rows,]
			
			bndMatches <- stringr::str_match(cgr$ALT, "(.*)(\\[|])(.*)(\\[|])(.*)")
			preBases <- bndMatches[,2]
			bracket <- bndMatches[,3]
			remoteLocation <- bndMatches[,4]
			postBases <- bndMatches[,6]
			strand(cgr) <- ifelse(preBases == "", "-", "+")
			if (!is.null(info(cvcf)$IMPRECISE_DIR)) {
				# LongRanger
				strand(cgr) <- ifelse(info(cvcf)$IMPRECISE_DIR, "*", as.character(strand(cgr)))
			}
			
			cgr$partner <- NA_character_
			if (!is.null(info(cvcf)$PARID)) {
				cgr$partner <- elementExtract(info(cvcf)$PARID, 1)
			}
			if (!is.null(info(cvcf)$MATEID) & any(is.na(cgr$partner))) {
				multimates <- S4Vectors::elementNROWS(info(cvcf)$MATEID) > 1 & is.na(cgr$partner)
				cgr$partner <- ifelse(is.na(cgr$partner), elementExtract(info(cvcf)$MATEID, 1), cgr$partner)
				if (any(multimates)) {
					warning(paste("Ignoring additional mate breakends for variants.", names(cgr)[multimates]))
				}
			}
			reflen <- S4Vectors::elementNROWS(cgr$REF)
			cgr$insSeq <- paste0(stringr::str_sub(preBases, reflen + 1), stringr::str_sub(postBases, end=-(reflen + 1)))
			cgr$insLen <- nchar(cgr$insSeq)
			
			isMissingPartner <- is.na(cgr$partner) | !(cgr$partner %in% names(cgr))
			if (any(isMissingPartner)) {
				if (inferMissingBreakends) {
					remoteChrPos = stringr::str_split_fixed(remoteLocation, stringr::fixed(":"), n=2)
					remoteChr = remoteChrPos[,1]
					remotePos = as.numeric(remoteChrPos[,2])
					ipgr = GRanges(seqnames=remoteChr, ranges=IRanges::IRanges(start=remotePos, end=remotePos), strand=ifelse(bracket=="[", "-", "+"))
					mcols(ipgr) = mcols(cgr)
					ipgr$REF = "N"
					ipgr$ALT = paste0(
						ifelse(as.logical(strand(ipgr) == "+"), "N", ""),
						ifelse(as.logical(strand(cgr) == "+"), "]", "["),
						seqnames(cgr),
						":",
						start(cgr),
						ifelse(as.logical(strand(cgr) == "+"), "]", "["),
						ifelse(as.logical(strand(ipgr) == "+"), "", "N"))
					mpgr <- cgr[isMissingPartner,]
					ipgr <- ipgr[isMissingPartner,]
					names(ipgr) = paste0("svrecord", length(gr) + seq_len(length(ipgr)), "_bp2")
					mpgr$partner = names(ipgr)
					ipgr$partner = names(mpgr)
					outgr <- c(outgr, mpgr, ipgr)
				} else {
					warning(paste("Removing", sum(isMissingPartner), "unpaired breakend variants. Use inferMissingBreakends=TRUE to recover with inferred partner breakends. Missing breakends: ", paste0(names(cgr)[isMissingPartner], collapse=", ")))
				}
				cgr <- cgr[!isMissingPartner,]
			}
			mategr <- cgr[cgr$partner,]
			cgr$svLen <- ifelse(GenomeInfoDb::seqnames(cgr)==GenomeInfoDb::seqnames(mategr), abs(start(cgr) - start(mategr)) - 1, NA_integer_)
			# make deletion-like events have a -ve svLen
			cgr$svLen <- ifelse(strand(cgr) != strand(mategr) &
									((start(cgr) < start(mategr) & strand(cgr) == "+") |
									 	(start(cgr) > start(mategr) & strand(cgr) == "-")),
								-cgr$svLen, cgr$svLen)
			cgr$svLen <- cgr$svLen + cgr$insLen
			outgr <- c(outgr, cgr)
		}
		cgr <- NULL
		mategr <- NULL
	}
	# breakends that are not in breakpoint notation should be in breakend notation
	rows <- !gr$processed & !is.na(gr$svtype) & gr$svtype %in% c("BND")
	if (any(rows)) {
		cgr <- gr[rows,]
		gr$processed[rows] <- TRUE
		if (unpartneredBreakends) {
			cvcf <- vcf[rows,]
			strand(cgr) <- ifelse(cgr$ALT == "", "*", ifelse(stringr::str_sub(cgr$ALT, 1, 1) == ".", "-", "+"))
			# trim anchoring base and breakend symbol
			cgr$insSeq <- stringr::str_sub(cgr$ALT, 2, stringr::str_length(cgr$ALT) - 1)
			cgr$insLen <- stringr::str_length(cgr$insSeq)
			cgr$partner <- NA_character_
			cgr$svLen <- NA_integer_
			outgr <- c(outgr, cgr)
		}
		cgr <- NULL
	}
	# TODO: Does delly write two records for a full INV?
	# DELLY TRA https://groups.google.com/forum/#!msg/delly-users/6Mq2juBraRY/BjmMrBh3GAAJ
	rows <- !gr$processed & !is.na(gr$svtype) & gr$svtype %in% c("TRA")
	if (any(rows)) {
		cgr <- gr[rows,]
		gr$processed[rows] <- TRUE
		if (!unpartneredBreakends) {
			cvcf <- vcf[rows,]
			
			if (is.null(info(cvcf)$CHR2) || any(is.na(info(cvcf)$CHR2))) {
				stop(paste("Delly variants missing CHR2:", paste(names(cgr)[is.na(info(cvcf)$CHR2)], collapse=", ")))
			}
			if (is.null(info(cvcf)$CT) || any(is.na(info(cvcf)$CT))) {
				stop(paste("Delly variants missing CT:", paste(names(cgr)[is.na(info(cvcf)$CT)], collapse=", ")))
			}
			cgr$insLen <- .replaceNa(info(cvcf)$INSLEN, 0) # Delly no longer writes INSLEN to all TRA records
			width(cgr) <- 1
			mategr <- cgr
			# Hack so we can add new seqlevels if required
			GenomeInfoDb::seqlevels(mategr) <- unique(c(GenomeInfoDb::seqlevels(mategr), info(cvcf)$CHR2))
			GenomeInfoDb::seqnames(mategr)[seq(1, length(mategr))] <- info(cvcf)$CHR2
			ranges(mategr) <- IRanges::IRanges(start=info(cvcf)$END, width=1)
			strand(cgr) <- ifelse(info(cvcf)$CT %in% c("3to3", "3to5"), "+", "-")
			strand(mategr) <- ifelse(info(cvcf)$CT %in% c("3to3", "5to3"), "+", "-")
			
			mcistartoffset <- .replaceNa(elementExtract(info(cvcf)$CIEND, 1), 0)
			mciendoffset <- .replaceNa(elementExtract(info(cvcf)$CIEND, 2), 0)
			mciwidth <- mciendoffset - mcistartoffset
			mategr$cistartoffset <- mcistartoffset
			mategr$ciwidth <- mciwidth
			
			names(mategr) <- paste0(names(cgr), suffix, 2)
			names(cgr) <- paste0(names(cgr), suffix, 1)
			cgr$partner <- names(mategr)
			mategr$partner <- names(cgr)
			outgr <- c(outgr, cgr, mategr)
		}
		cgr <- NULL
		mategr <- NULL
	}
	# TIGRA CTX
	rows <- !gr$processed & !is.na(gr$svtype) & gr$svtype %in% c("CTX")
	if (any(rows)) {
		# TIGRA CTX call
		cgr <- gr[rows,]
		gr$processed[rows] <- TRUE
		if (!unpartneredBreakends) {
			cvcf <- vcf[rows,]
			
			if (is.null(info(cvcf)$CHR2) || any(is.na(info(cvcf)$CHR2))) {
				stop(paste("TIGRA variants missing CHR2:", paste(names(cgr)[is.na(info(cvcf)$CHR2)], collapse=", ")))
			}
			width(cgr) <- 1
			mategr <- cgr
			# Hack so we can add new seqlevels if required
			GenomeInfoDb::seqlevels(mategr) <- unique(c(GenomeInfoDb::seqlevels(mategr), info(cvcf)$CHR2))
			GenomeInfoDb::seqnames(mategr)[seq(1, length(mategr))] <- info(cvcf)$CHR2
			ranges(mategr) <- IRanges::IRanges(start=info(cvcf)$END, width=1)
			# no direction information is reported
			strand(cgr) <- "*"
			strand(mategr) <- "*"
			
			mcistartoffset <- .replaceNa(elementExtract(info(cvcf)$CIEND, 1), 0)
			mciendoffset <- .replaceNa(elementExtract(info(cvcf)$CIEND, 2), 0)
			mciwidth <- mciendoffset - mcistartoffset
			mategr$cistartoffset <- mcistartoffset
			mategr$ciwidth <- mciwidth
			
			names(mategr) <- paste0(names(cgr), suffix, 2)
			names(cgr) <- paste0(names(cgr), suffix, 1)
			cgr$partner <- names(mategr)
			mategr$partner <- names(cgr)
			outgr <- c(outgr, cgr, mategr)
		}
		cgr <- NULL
		mategr <- NULL
	}
	if (!ignoreUnknownSymbolicAlleles && !all(gr$processed)) {
		stop(paste("Unrecognised format for variants. Set ignoreUnknownSymbolicAlleles=TRUE to ignore variants. Problematic records are: ", paste(names(gr)[!gr$processed], collapse=", ")))
	}
	# incorporate microhomology and confidence intervals
	if (!nominalPosition) {
		ranges(outgr) <- IRanges::IRanges(start=start(outgr) + outgr$cistartoffset, width=outgr$ciwidth + 1, names=names(outgr))
	}
	outgr$processed <- NULL
	outgr$cistartoffset <- NULL
	outgr$ciwidth <- NULL
	if (!unpartneredBreakends) {
		partnerpartnerisself <- outgr[outgr$partner]$partner == names(outgr)
		if (!all(partnerpartnerisself)) {
			warning("Multiple breakends partners for a single breakend found (Ignoring all except first). StructuralVariantAnnotation does not support promiscuous breakpoints.")
			outgr <- outgr[partnerpartnerisself,]
		}
		# sanity check that all breakpoints partners actually exist
		haspartner <- outgr$partner %in% names(outgr)
		if (!all(haspartner)) {
			stop(paste("Sanity check failure: unpaired breakends ", paste(names(gr)[!haspartner], collapse=", ")))
		}
	} else {
		outgr$partner <- NULL
	}
	return(outgr)
}
#' Extracting unpartnered breakend structural variants as a GRanges
#'
#' @details
#' The VCF standard supports single breakends where a breakend is not part of a
#' novel adjacency and lacks a mate. This function supports parsing single
#' breakends to GRanges, where a dot symbol is used in the ALT field to annotate
#' the directional information. Single breakends provide insights to situations
#' when one side of the structural variant is not observed, due to e.g. low
#' mappability, non-reference contigs, complex multi-break operations, etc.
#' See Section 5.4.9 of \url{https://samtools.github.io/hts-specs/VCFv4.3.pdf}
#' for details of single breakends.
#' @param x A VCF object.
#' @param ... Parameters of \code{.breakpointRanges()}. See breakpointRanges for
#' more details.
#' @return A GRanges object of SVs.
#' @examples
#' vcf.file <- system.file("extdata", "gridss.vcf",
#'                          package = "StructuralVariantAnnotation")
#' vcf <- VariantAnnotation::readVcf(vcf.file, "hg19")
#' breakendRanges(vcf)
#' breakendRanges(vcf, nominalPosition=TRUE)
#' @export
setGeneric("breakendRanges", signature="x",
		   function(x, ...)
		   	standardGeneric("breakendRanges")
)
#' @describeIn breakendRanges Extracting unpartnered structural variants as 
#' GRanges.
setMethod("breakendRanges", "VCF",
		  function(x, ...)
		  	.breakpointRanges(x, unpartneredBreakends=TRUE, ...)
)
# .breakendRanges <- function(vcf, nominalPosition=FALSE, 
#                             placeholderName="svrecord", suffix="_bp", 
#                             info_columns=NULL) {}

#' @noRd
.hasMetadataInfo <- function(vcf, field) {
	return(field %in% row.names(info(header(vcf))))
}
#' @noRd
.expectMetadataInfo <- function(vcf, field, number, type) {
	assertthat::assert_that(.hasMetadataInfo(vcf, field))
	row <- info(header(vcf))[field,]
	assertthat::assert_that(type == row$Type)
	assertthat::assert_that(number == row$Number)
}

#' Adjusting the nominal position of a pair of partnered breakpoint.
#' @param vcf A VCF object.
#' @param align The alignment type.
#' @param is_higher_breakend Breakpoint ID ordering.
#' @return A VCF object with adjusted nominal positions.
align_breakpoints <- function(vcf, align=c("centre"), is_higher_breakend=names(vcf) < info(vcf)$PARID) {
	if (length(vcf) == 0) {
		return(vcf)
	}
	align = match.arg(align)
	if (!all(S4Vectors::elementNROWS(info(vcf)$CIPOS) == 2)) {
		stop("CIPOS not specified for all variants.")
	}
	is_higher_breakend[is.na(is_higher_breakend)] = FALSE
	nominal_start = start(SummarizedExperiment::rowRanges(vcf))
	cipos = t(matrix(unlist(info(vcf)$CIPOS), nrow=2))
	ciwdith = cipos[,2] - cipos[,1]
	orientations = .vcfAltToStrandPair(SummarizedExperiment::rowRanges(vcf)$ALT)
	if (align == "centre") {
		citargetpos = nominal_start + cipos[,1] + ciwdith / 2.0
		adjust_by = citargetpos - nominal_start
		adjust_in_opposite_direction_to_partner = orientations %in% c("--", "++")
		adjust_by = ifelse(is_higher_breakend & adjust_in_opposite_direction_to_partner, ceiling(adjust_by), floor(adjust_by))
	} else {
		stop("Only centre alignment is currently implemented.")
	}
	isbp = stringr::str_detect(VariantAnnotation::fixed(vcf)$ALT, "[\\]\\[]")
	is_adjusted_bp =  isbp & !is.na(adjust_by) & adjust_by != 0
	SummarizedExperiment::rowRanges(vcf) = shift(SummarizedExperiment::rowRanges(vcf), ifelse(!is_adjusted_bp, 0, adjust_by))
	info(vcf)$CIPOS = info(vcf)$CIPOS - adjust_by
	if (!is.null(info(vcf)$CIEND)) {
		info(vcf)$CIEND = info(vcf)$CIEND - adjust_by
	}
	if (!is.null(info(vcf)$IHOMPOS)) {
		info(vcf)$IHOMPOS = info(vcf)$IHOMPOS - adjust_by
	}
	alt = unlist(SummarizedExperiment::rowRanges(vcf)$ALT)
	partner_alt = stringr::str_match(alt, "^([^\\]\\[]*)[\\]\\[]([^:]+):([0-9]+)([\\]\\[])([^\\]\\[]*)$")
	# [,2] anchoring bases
	# [,3] partner chr
	# [,4] old partner position
	partner_pos = ifelse(is.na(partner_alt[,4]), NA_integer_, as.integer(partner_alt[,4])) + ifelse(adjust_in_opposite_direction_to_partner, -adjust_by, adjust_by)
	# [,5] partner orientation
	# [,6] anchoring bases
	# adjust ALT for breakpoints. anchoring bases get replaced with N since we don't know
	VariantAnnotation::fixed(vcf)$ALT = as(ifelse(!is_adjusted_bp, alt,
												  paste0(
												  	stringr::str_pad("", stringr::str_length(partner_alt[,2]), pad="N"),
												  	partner_alt[,5],
												  	partner_alt[,3],
												  	":",
												  	partner_pos,
												  	partner_alt[,5],
												  	stringr::str_pad("", stringr::str_length(partner_alt[,6]), pad="N"))), "CharacterList")
	info(vcf)$CIRPOS = NULL # TODO: remove CIRPOS from GRIDSS entirely
	return(vcf)
}
#' @noRd
.vcfAltToStrandPair = function(alt) {
	chralt = unlist(alt)
	ifelse(startsWith(chralt, "."), "-",
		   ifelse(endsWith(chralt, "."), "+",
		   	   ifelse(startsWith(chralt, "]"), "-+",
		   	   	   ifelse(startsWith(chralt, "["), "--",
		   	   	   	   ifelse(endsWith(chralt, "]"), "++",
		   	   	   	   	   ifelse(endsWith(chralt, "["), "+-", ""))))))
	
}
#' Calculates the confidence interval around the end of a SV
#' represented using symbolic allele notation
#' @param cistartoffset confidence interval start offset around start of SV
#' @param ciwidthconfidence interval width around start of SV
#' @param svtype type of SV. Variants which are not INS, DEL, DUP, INV are treated as DEL
#' @param len length of SV
#' @noRd
.calc_right_confidence_interval = function(
		cistartoffset,
		ciwidth,
		svtype,
		len,
		ciend,
		cilen) {
	# CIEND
	ciend_startoffset = NULL
	ciend_width = NULL
	if (!is.null(ciend)) {
		ciend_startoffset <- elementExtract(ciend, 1)
		ciend_endoffset   <- elementExtract(ciend, 2)
		ciend_width <- ciend_endoffset - ciend_startoffset
	}
	if (!is.null(cilen)) {
		# CILEN offsets compound on top of starting CIPOS bounds
		cilen_min = elementExtract(cilen, 1)
		cilen_max = elementExtract(cilen, 2)
		cistartoffset = cistartoffset + .replaceNa(ifelse(svtype %in% c("INS"), 0, cilen_min), 0)
		ciwidth = ciwidth + .replaceNa(ifelse(svtype %in% c("INS"), 0, cilen_max - cilen_min), 0)
	}
	list(
		cistartoffset=.replaceNa(ciend_startoffset, cistartoffset),
		ciwidth=.replaceNa(ciend_width, ciwidth))
}