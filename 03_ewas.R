source("config")
source("config.R")
design = read.table("sample.txt", sep=";", header=TRUE, stringsAsFactors=FALSE)
rownames(design) = design$sampleID
design
cov_files = paste0("~/projects/", datashare, "/", gse, "/", design$bed_file)

if (! exists("mgzread.table")) {
  gzread.table = function (f, cov_thresh, ...) {
    print(f)
    d = read.table(gzfile(f), ...)
    d[d[,1]=="chrM",1] = "chrMT"
    colnames(d) = c("chr", "pos", "pos2", "meth", "nb_meth", "nb_umeth")
    rownames(d) = paste0(d$chr, "_", d$pos)
    d$cov = d$nb_meth + d$nb_umeth
    d[d$cov>=cov_thresh,]
  }
  mgzread.table = memoise::memoise(gzread.table)
}

# for ( cov_thresh in cov_threshs) {
#   print(cov_thresh)
#   covs = lapply(cov_files, mgzread.table, stringsAsFactors=FALSE, cov_thresh=cov_thresh)
# }
#
# cov_thresh = 30
# foo = mgzread.table(cov_files[1], stringsAsFactors=FALSE, cov_thresh=cov_thresh)
# head(foo)
# tail(foo)
# table(foo$chr)

dir.create(path="ewas_results", showWarnings=FALSE) 
for (cov_thresh in cov_threshs) {
  ewas_filename = paste0("ewas_results/ewas_covthresh", cov_thresh, ".rds")
  if (!file.exists(ewas_filename)) {
    print(paste0("Computing ", ewas_filename, "."))
    covs = lapply(cov_files, mgzread.table, stringsAsFactors=FALSE, cov_thresh=cov_thresh)
    table(covs[[1]]$chr)
    names(covs) = design$sampleID
  
    idx2 =   unique(unlist(lapply(covs, rownames)))
    length(idx2)

    # Remove where no difference
    foo = matrix(NA, nrow=length(idx2), ncol=length(covs))
    dim(foo)
    rownames(foo) = idx2
    for (i in 1:length(covs)) {
      print(i)
      d = covs[[i]]
      head(d)
      idx = i
      tmp = as.matrix(d[rownames(d),4])
      foo[rownames(d),idx] = tmp
    }
    dim(foo)
    unique_naomit = function(v) {
      unique(na.omit(v))
      # unique(v[!is.na(v)]
    }
    bar = epimedtools::monitored_apply(foo, 1, unique_naomit, mod=10000)
    baz = sapply(bar, length)
    table(baz)
    idx3 = names(baz)[baz>1]
    print(paste0("#CpG with differences: ", length(idx3)))


    # Remove where less than XXX replicates
    nb_rep_min = 3
    idx4s = lapply(unique(design$treatment), function(cond) {
      card_cond = sum(design$treatment==cond)
      foo = matrix(NA, nrow=length(idx3), ncol=card_cond)
      dim(foo)
      rownames(foo) = idx3
      colnames(foo) = design[design$treatment==cond,]$sampleID
      for (id in colnames(foo)) {
        print(id)
        d = covs[[id]]
        head(d)
        idx_pos = intersect(rownames(d), idx3)
        tmp = as.matrix(d[idx_pos,4])
        foo[idx_pos,id] = tmp
      }
      dim(foo)
      bar = epimedtools::monitored_apply(!is.na(foo), 1, sum, mod=10000)
      table(bar)
      idx4 = names(bar)[bar>=nb_rep_min]
      idx4
    })
    idx5 = do.call(epimedtools::intersect_rec, idx4s)
    print(paste0("#CpG with at least nb_rep_min in all conditions: ", length(idx5)))    


    # Fill matrix for ewas
    data_for_ewas = matrix(NA, nrow=length(idx5), ncol=nrow(design))
    dim(data_for_ewas)
    rownames(data_for_ewas) = idx5
    colnames(data_for_ewas) = design$sampleID

    for (id in colnames(data_for_ewas)) {
      print(id)
      d = covs[[id]]
      head(d)
      idx_pos = intersect(rownames(d), rownames(data_for_ewas))
      data_for_ewas[idx_pos,id] = d[idx_pos,]$meth
    }
    dim(data_for_ewas)
  
    # EWAS
    if (!exists("cl")) {
      nb_cores = parallel::detectCores()
      cl  = parallel::makeCluster(nb_cores,  type="FORK")
      # parallel::stopCluster(cl)
    }
    ewas = parallel::parApply(cl, data_for_ewas, 1, function(l) { #})
    # ewas = epimedtools::monitored_apply(mod=1, data_for_ewas, 1, function(l) { #})
      # ({
      # l = data_for_ewas[1,]
      # l = data_for_ewas[1158,]
      idx_cond1 = which(design[colnames(data_for_ewas),]$treatment==unique(design$treatment)[1])
      idx_cond2 = which(design[colnames(data_for_ewas),]$treatment==unique(design$treatment)[2])    
      beta = mean(l[idx_cond1], na.rm=TRUE) - mean(l[idx_cond2], na.rm=TRUE)
      # test t
      ttest = try(t.test(l[idx_cond1], l[idx_cond2]), silent=TRUE)
      if (attributes(ttest)$class == "try-error") {
        pval_t = 1
      } else{
        pval_t = ttest$p.value      
      }
      # wilcox
      wtest = wilcox.test(l[idx_cond1], l[idx_cond2])
      pval_w = wtest$p.value
      # robust regression
      meth = l[c(idx_cond1, idx_cond2)]
      treatment = as.factor(design[c(idx_cond1, idx_cond2),]$treatment)
      rtest = MASS::rlm(meth~treatment, maxit=400)  
      beta_r = rtest$coefficients[[2]]
      if (is.na(beta_r)) {
        pval_r = NA
      } else {        
        pval_r = survey::regTermTest(rtest, "treatment", null=NULL, df=Inf, method=c("Wald"))$p
      }
      nb_cond1=sum(!is.na(l[idx_cond1]))
      nb_cond2=sum(!is.na(l[idx_cond2]))
      ret = c(pval_t=pval_t, pval_w=pval_w, pval_r=pval_r, beta=beta, beta_r=beta_r, nb_cond1=nb_cond1, nb_cond2=nb_cond2)
      ret
    })
    saveRDS(ewas, ewas_filename)
  } else {
    print(paste0(ewas_filename, " exists."))
  }
}

pdf("ewas_results/pval_dist.pdf")
# layout(matrix(1:(3*length(cov_threshs)),3), respect=TRUE)
for (cov_thresh in cov_threshs) {
  ewas_filename = paste0("ewas_results/ewas_covthresh", cov_thresh, ".rds")
  ewas = t(readRDS(ewas_filename))
  head(ewas)
  for (pv in colnames(ewas)[1:3]) {
    plot(density(na.omit(-log10(ewas[,pv]))), main=paste(cov_thresh, pv))      
  }
}
dev.off()




sessionInfo()





