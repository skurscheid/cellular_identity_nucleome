__author__ = "Sebastian Kurscheid (sebastian.kurscheid@anu.edu.au)"
__license__ = "MIT"
__date__ = "2020-02-04"

# vim: syntax=python tabstop=4 expandtab
# coding: utf-8


"""
Rules for aligning reads with bowtie2
(https://github.com/BenLangmead/bowtie2)

For usage, include this in your workflow.
"""

def get_index(machine, config):
    """ returns path to index"""
    return config["params"]["bowtie2"]["index"][machine]

singularity: "docker://skurscheid/snakemake_baseimage:0.2"

rule bowtie2_se_global:
    """ runs alignment of single-end fastq file, modified parameters specific for HiC data"""
    conda:
        "../envs/fastqProcessing.yaml"
    threads:
        8
    params:
        index = get_index("gadi", config),
        cli_params_global = config['params']['bowtie2']['cli_params_global']
    log:
        log = "logs/bowtie2_global/{biosample}/{rep}/{run}{end}.log"
    input:
        fq = "fastp/trimmed/se/{biosample}/{rep}/{run}{end}.fastq.gz"
    output:
        bam = "bowtie2/align_global/se/{biosample}/{rep}/{run}{end}.bam",
        unmapped = "bowtie2/align_global/se/{biosample}/{rep}/{run}{end}.unmap.fastq"
    shell:
        """
            bowtie2\
                    -x {params.index}\
                    -p {threads}\
                    -U {input.fq}\
                    {params.cli_params_global}\
                    --un {output.unmapped}\
                    --rg-id BMG\
                    --rg SM:{wildcards.biosample}:{wildcards.run}\
                    2>> {log.log}\
            | samtools view -Shb - > {output.bam}
        """

rule cutsite_trimming:
    """trims potentially chimeric reads prior to second alignment"""
    version:
        1
    params:
        hicpro_dir = config['params']['hicpro']['install_dir']['gadi'],
        cutsite = "AAGCTT" #HindIII
    log:
        log = "logs/cutsite_trimming/{biosample}/{rep}/{run}{end}.log"
    input:
        rules.bowtie2_se_global.output.unmapped
    output:
        cutsite_trimmed = temp("cutsite_trimming/{biosample}/{rep}/{run}{end}.fastq")
    shell:
        """ 
            {params.hicpro_dir}/scripts/cutsite_trimming --fastq {input} --cutsite {params.cutsite} --out {output}
        """

rule bowtie2_se_local:
    """ runs alignment of single-end fastq file, modified parameters specific for HiC data"""
    version:
        1
    conda:
        "../envs/fastqProcessing.yaml"
    threads:
        8
    params:
        index = get_index("gadi", config),
        cli_params_local = config['params']['bowtie2']['cli_params_local']
    log:
        log = "logs/bowtie2_local/{biosample}/{rep}/{run}{end}.log"
    input:
        fq = rules.cutsite_trimming.output
    output:
        bam = temp("bowtie2/align_local/se/{biosample}/{rep}/{run}{end}.bam"),
        unmapped = temp("bowtie2/align_local/se/{biosample}/{rep}/{run}{end}.unmap.fastq")
    shell:
        """
            bowtie2\
                    -x {params.index}\
                    -p {threads}\
                    -U {input.fq}\
                    {params.cli_params_local}\
                    --un {output.unmapped}\
                    --rg-id BML\
                    --rg SM:{wildcards.biosample}:{wildcards.run}\
                    2>> {log.log}\
            | samtools view -Shb - > {output.bam}
        """

rule samtools_merge_local_global:
    """ merges BAM files from global and local alignmnent steps """
    version:
        1
    conda:
        "../envs/hicpro.yaml"
    threads:
        8
    params:
    log:
        log = "logs/samtools_merge/{biosample}/{rep}/{run}{end}.log"
    input:
        bam1 = rules.bowtie2_se_global.output.bam,
        bam2 = rules.bowtie2_se_local.output.bam
    output:
        mergedBam = "samtools/merge/se/{biosample}/{rep}/{run}{end}.bam"
    shell:
        """
            samtools merge -@ {threads} -n -f {output.mergedBam} {input.bam1} {input.bam2}
        """

rule samtools_sort_merged_bam:
    """ sorts the BAM files from merge step """
    version:
        1
     conda:
        "../envs/hicpro.yaml"
    threads:
        8
    params:
        tempPrefix = "temp/{run}_{end}"
    log:
        log = "logs/samtools_sort/{biosample}/{replicate}/{run}_{end}.log"
    input:
        rules.output.samtools_merge_local_global.mergedBam
    output:
        sortedBam = "samtools/sort/se/{biosample}/{rep}/{run}_{end}.bam"
    """
        samtools sort -@ {threads} -n -T {params.tempPrefix} -o {output.sortedBam} {input}
    """

rule combine_bam_files:
    """ combines SE BAM files to a single PE BAM file with additional filtering """
    version:
        1
    conda:
        "../envs/hicpro.yaml"
    threads:
        2
    params:
        hicpro_dir = config['params']['hicpro']['install_dir']['gadi'],
        qual = config['params']['general']['alignment_quality']
    log:
        log = "logs/mergeSAM/{biosample}/{rep}/{run}.log",
        stat = "mergeSam/combine/pe/{biosample}/{rep}/{run}_stats.txt"
    input:
        bam1 = lambda wildcards: "/".join(["samtools", "merge", "se", wildcards["biosample"], wildcards["rep"], wildcards["run"]]) + config["params"]["general"]["end1_suffix"] + ".bam",
        bam2 = lambda wildcards: "/".join(["samtools", "merge", "se", wildcards["biosample"], wildcards["rep"], wildcards["run"]]) + config["params"]["general"]["end2_suffix"] + ".bam"
    output:
        combinedBam = "mergeSam/combine/pe/{biosample}/{rep}/{run}.bam"
    shell:
        """ 
            python {params.hicpro_dir}/scripts/mergeSAM.py -f {input.bam1} -r {input.bam2} -o {output.combinedBam} -q {params.qual} -t {log.stat} 2>>{log.log}
        """

