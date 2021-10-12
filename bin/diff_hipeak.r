#!/usr/bin/env Rscript

#######################################################################
#######################################################################
## Created on April. 29, 2021 call edgeR
## Copyright (c) 2021 Jianhong Ou (jianhong.ou@gmail.com)
#######################################################################
#######################################################################
pwd <- getwd()
pwd <- file.path(pwd, "lib")
dir.create(pwd)
.libPaths(c(pwd, .libPaths()))

library(edgeR)
library(InteractionSet)
writeLines(as.character(packageVersion("edgeR")), "edgeR.version.txt")
writeLines(as.character(packageVersion("InteractionSet")), "InteractionSet.version.txt")

prefix <- "diffhicar"
## load n.cores
args <- commandArgs(trailingOnly=TRUE)
if(length(args)>0){
    prefix <- args[[1]]
    args <- args[-1]
}
if(length(args)>0){
    args <- lapply(args, function(.ele) eval(parse(.ele)))
}else{
    args <- list()
}


## get peaks
pf <- dir("peaks", "peaks", full.names = TRUE)
peaks <- lapply(pf, read.table, header=TRUE)
### reduce the peaks
peaks <- unique(do.call(rbind, peaks)[, c("chr1", "start1", "end1",
                                        "chr2", "start2", "end2")])
peaks <- with(peaks, GInteractions(GRanges(chr1, IRanges(start1, end1)),
                                    GRanges(chr2, IRanges(start2, end2))))
reducePeaks <- function(x){
    y <- reduce(x)
    ol <- findOverlaps(x, y)
    stopifnot(all(seq_along(x) %in% queryHits(ol)))
    ol <- as.data.frame(ol)
    y[ol[match(seq_along(x), ol$queryHits), "subjectHits"]]
}
first <- reducePeaks(first(peaks))
second <- reducePeaks(second(peaks))
peaks <- unique(GInteractions(first, second))

## get counts
readPairs <- function(pair, chrom){
    if(file.exists(paste0(pair, ".rds"))){
        if(file.exists(paste0(pair, ".", chrom, ".rds"))){
            pc <- readRDS(paste0(pair, ".", chrom, ".rds"))
        }else{
            NULL
        }
    }else{
        pc <- read.table(pair,
                colClasses=c("NULL", "character",
                            "integer", "character",
                            "integer", rep("NULL", 9)))
        pc <- split(pc, pc[, 1])
        null <- mapply(saveRDS, pc, paste0(pair, ".", names(pc), ".rds"))
        saveRDS(TRUE, paste0(pair, ".rds"))
        if(chrom %in% names(pc)){
            pc[[chrom]]
        }else{
            NULL
        }
    }
}
pc <- dir("pairs", "pairs.gz", full.names = FALSE)
countByOverlaps <- function(pairs, peaks){
    cnt <- lapply(names(peaks), function(chr){
        ps <- readPairs(pairs, chr)
        counts_total <- nrow(ps)
        ps <- ps[ps[, 1]==ps[, 3], , drop=FALSE] ## focus on same fragment only (cis only)
        if(nrow(ps)<1){
            return(NULL)
        }
        ps <- GInteractions(GRanges(ps[, 1], IRanges(ps[, 2], width=150)),
                            GRanges(ps[, 3], IRanges(ps[, 4], width=150)))
        .peak <- peaks[[chr]]
        counts_tab <- countOverlaps(.peak, ps, use.region="same")
        counts_tab <- cbind(ID=.peak$ID, counts_tab)
        list(count=counts_tab, total=counts_total)
    })
    cnt <- cnt[lengths(cnt)>0]
    counts_total <- vapply(cnt, FUN=function(.ele) .ele$total,
                        FUN.VALUE = numeric(1))
    counts_total <- sum(counts_total)
    counts_tab <- do.call(rbind, lapply(cnt, function(.ele) .ele$count))
    list(count=counts_tab, total=counts_total)
}

peaks$ID <- seq_along(peaks)
peaks.s <- split(peaks, seqnames(first(peaks)))
cnts <- lapply(file.path("pairs", pc), countByOverlaps, peaks=peaks.s)
samples <- sub("(_REP\\d+)\\.(.*?)unselected.pairs.gz", "\\1", pc)
sizeFactor <- vapply(cnts, FUN=function(.ele) .ele$total,
                    FUN.VALUE = numeric(1))
names(sizeFactor) <- samples
cnts <- lapply(cnts, function(.ele) .ele$count)
cnts <- mapply(cnts, samples, FUN=function(.d, .n){
    colnames(.d)[colnames(.d)!="ID"] <- .n
    .d
}, SIMPLIFY=FALSE)
cnts <- Reduce(function(x, y) merge(x, y, by="ID"), cnts)
cnts <- cnts[match(peaks$ID, cnts[, "ID"]), ]
cnts <- cnts[, colnames(cnts)!="ID"]
colnames(cnts) <- samples
rownames(cnts) <- seq_along(peaks)
mcols(peaks) <- cnts

pf <- as.character(prefix)
dir.create(pf)

fname <- function(subf, ext, ...){
    pff <- ifelse(is.na(subf), pf, file.path(pf, subf))
    dir.create(pff, showWarnings = FALSE, recursive = TRUE)
    file.path(pff, paste(..., ext, sep="."))
}

## write counts
write.csv(peaks, fname(NA, "csv", "raw.counts"), row.names = FALSE)
## write sizeFactors
write.csv(sizeFactor, fname(NA, "csv", "library.size"), row.names = TRUE)

## coldata
sampleNames <- colnames(cnts)
condition <- make.names(sub("_REP.*$", "", sampleNames), allow_=TRUE)
coldata <- data.frame(condition=factor(condition),
                    row.names = sampleNames)
## write designtable
write.csv(coldata, fname(NA, "csv", "designTab"), row.names = TRUE)

contrasts.lev <- levels(coldata$condition)

if(length(contrasts.lev)>1 || any(table(condition)>1)){
    contrasts <- combn(contrasts.lev, 2, simplify = FALSE)
    ## create DGEList
    group <- coldata$condition
    y <- DGEList(counts = cnts,
                lib.size = sizeFactor,
                group = group)

    ## do differential analysis
    names(contrasts) <- vapply(contrasts,
                                FUN=paste,
                                FUN.VALUE = character(1),
                                collapse = "-")
    y <- calcNormFactors(y)
    design <- model.matrix(~0+group)
    colnames(design) <- levels(y$samples$group)
    y <- estimateDisp(y,design)
    fit <- glmQLFit(y, design)

    ## PCA
    pdf(fname(NA, "pdf", "Multidimensional.scaling.plot-plot"))
    mds <- plotMDS(y)
    dev.off()
    ## PCA for multiQC
    tryCatch({
    json <- data.frame(x=mds$x, y=mds$y)
    rownames(json) <- rownames(mds$distance.matrix.squared)
    json <- split(json, coldata[rownames(json), "condition"])
    json <- mapply(json, rainbow(n=length(json)), FUN=function(.ele, .color){
        .ele <- cbind(.ele, "name"=rownames(.ele))
        .ele <- apply(.ele, 1, function(.e){
            x <- names(.e)
            y <- .e
            .e <- paste0('{"x":', .e[1],
                        ', "y":', .e[2],
                        ', "color":"', .color,
                        '", "name":"', .e[3],
                        '"}')
        })
        .ele <- paste(.ele, collapse=", ")
        .ele <- paste("[", .ele, "]")
    })
    json <- paste0('"', names(json), '" :', json)
    json <- c(
            "{",
            '"id":"sample_pca",',
            '"data":{',
            paste(unlist(json), collapse=", "),
            "}",
            "}")
    writeLines(json, fname(NA, "json", "HiPeak.Multidimensional.scaling.qc"))
    }, error=function(e) message(e))

    ## plot dispersion
    pdf(fname(NA, "pdf", "DispersionEstimate-plot"))
    plotBCV(y)
    dev.off()
    ## plot QL dispersions
    pdf(fname(NA, "pdf", "Quasi-Likelihood-DispersionEstimate-plot"))
    plotQLDisp(fit)
    dev.off()

    res <- mapply(contrasts, names(contrasts), FUN = function(cont, name){
        BvsA <- makeContrasts(contrasts = name, levels = design)
        qlf <- glmQLFTest(fit, contrast = BvsA)
        rs <- topTags(qlf, n = nrow(qlf), sort.by = "none")
        ## MD-plot
        pdf(fname(name, "pdf", "Mean-Difference-plot", name))
        plotMD(qlf)
        abline(h=0, col="red", lty=2, lwd=2)
        dev.off()
        ## PValue distribution
        pdf(fname(name, "pdf", "PValue-distribution-plot", name))
        hist(rs$table$PValue, breaks = 20)
        dev.off()
        ## save res
        res <- as.data.frame(rs)
        res <- cbind(peaks[as.numeric(rownames(res))], res)
        colnames(res) <- sub("seqnames", "chr", colnames(res))
        write.csv(res, fname(name, "csv", "edgeR.DEtable", name), row.names = FALSE)
        ## save metadata
        elementMetadata <- do.call(rbind, lapply(c("adjust.method","comparison","test"), function(.ele) rs[[.ele]]))
        rownames(elementMetadata) <- c("adjust.method","comparison","test")
        colnames(elementMetadata)[1] <- "value"
        write.csv(elementMetadata, fname(name, "csv", "edgeR.metadata", name), row.names = TRUE)
        ## save subset results
        res.s <- res[res$FDR<0.05 & abs(res$logFC)>1, ]
        write.csv(res.s, fname(name, "csv", "edgeR.DEtable", name, "padj0.05.lfc1"), row.names = FALSE)
        ## Volcano plot
        res$qvalue <- -10*log10(res$PValue)
        pdf(fname(name, "pdf", "Volcano-plot", name))
        plot(x=res$logFC, y=res$qvalue,
            main = paste("Volcano plot for", name),
            xlab = "log2 Fold Change", ylab = "-10*log10(P-value)",
            type = "p", col=NA)
        res.1 <- res
        if(nrow(res.1)>0) points(x=res.1$logFC, y=res.1$qvalue, pch = 20, cex=.5, col="gray80")
        if(nrow(res.s)>0) points(x=res.s$logFC, y=res.s$qvalue, pch = 19, cex=.5, col=ifelse(res.s$logFC>0, "brown", "darkblue"))
        dev.off()
        res$qvalue <- -10*log10(res$PValue)
        png(fname(name, "png", "Volcano-plot", name))
        plot(x=res$logFC, y=res$qvalue,
            main = paste("Volcano plot for", name),
            xlab = "log2 Fold Change", ylab = "-10*log10(P-value)",
            type = "p", col=NA)
        res.1 <- res
        if(nrow(res.1)>0) points(x=res.1$logFC, y=res.1$qvalue, pch = 20, cex=.5, col="gray80")
        if(nrow(res.s)>0) points(x=res.s$logFC, y=res.s$qvalue, pch = 19, cex=.5, col=ifelse(res.s$logFC>0, "brown", "darkblue"))
        dev.off()
    })
}
