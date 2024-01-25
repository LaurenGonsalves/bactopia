// Import generic module functions 
include { get_resources; initOptions; saveFiles } from '../../../lib/nf/functions'
RESOURCES     = get_resources(workflow.profile, params.max_memory, params.max_cpus)
options       = initOptions(params.containsKey("options") ? params.options : [:], 'kraken2')
options.btype = options.btype ?: "tools"
conda_tools   = "bioconda::bactopia-teton=1.0.2"
conda_name    = conda_tools.replace("=", "-").replace(":", "-").replace(" ", "-")
conda_env     = file("${params.condadir}/${conda_name}").exists() ? "${params.condadir}/${conda_name}" : conda_tools

process KRAKEN2 {
    tag "$meta.id"
    label 'process_high'

    conda (params.enable_conda ? conda_env : null)
    container "${ workflow.containerEngine == 'singularity' && !params.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/bactopia-teton:1.0.2--hdfd78af_0' :
        'quay.io/biocontainers/bactopia-teton:1.0.2--hdfd78af_0' }"

    input:
    tuple val(meta), path(reads)
    path db

    output:
    tuple val(meta), path('*.kraken2.report.txt')              , emit: kraken2_report
    tuple val(meta), path('*.scrub.report.tsv')                , emit: scrub_report, optional: true
    tuple val(meta), path("*.${classified_naming}*.fastq.gz")  , emit: classified, optional: true
    tuple val(meta), path("*.${unclassified_naming}*.fastq.gz"), emit: unclassified, optional: true
    path "*.{log,err}" , emit: logs, optional: true
    path ".command.*"  , emit: nf_logs
    path "versions.yml", emit: versions

    script:
    prefix = options.suffix ? "${options.suffix}" : "${meta.id}"
    def paired = meta.single_end ? "" : "--paired"
    classified_naming = params.wf == "teton" ? "host" : "classified"
    classified = meta.single_end ? "${prefix}.${classified_naming}.fastq"   : "${prefix}.${classified_naming}#.fastq"
    unclassified_naming = params.wf == "teton" ? "scrubbed" : "unclassified"
    unclassified = meta.single_end ? "${prefix}.${unclassified_naming}.fastq" : "${prefix}.${unclassified_naming}#.fastq"
    def is_tarball = db.getName().endsWith(".tar.gz") ? true : false
    """
    if [ "$is_tarball" == "true" ]; then
        mkdir database
        tar -xzf $db -C database
        KRAKEN_DB=\$(find database/ -name "hash.k2d" | sed 's=hash.k2d==')
    else
        KRAKEN_DB=\$(find $db/ -name "hash.k2d" | sed 's=hash.k2d==')
    fi

    kraken2 \\
        --db \$KRAKEN_DB \\
        --threads $task.cpus \\
        --unclassified-out $unclassified \\
        --classified-out $classified \\
        --report ${prefix}.kraken2.report.txt \\
        --gzip-compressed \\
        $paired \\
        $options.args \\
        $reads > /dev/null

    # Clean up large files produced by Kraken2/Bracken
    if [ "${params.remove_filtered_reads}" == "true" ]; then
        # Remove filtered FASTQs
        rm *.fastq
    else
        # Compress Kraken FASTQs
        pigz -p $task.cpus *.fastq
    fi

    if [ "$unclassified_naming" == "scrubbed" ]; then
        # Quick stats on reads
        zcat ${reads} | fastq-scan > original.json
        zcat ${prefix}.scrubbed* | fastq-scan > scrubbed.json
        scrubber-summary.py ${prefix} original.json scrubbed.json > ${prefix}.scrub.report.tsv

        # Remove host reads
        rm ${prefix}.host*.fastq.gz
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        fastq-scan: \$(echo \$(fastq-scan -v 2>&1) | sed 's/fastq-scan //')
        kraken2: \$(echo \$(kraken2 --version 2>&1) | sed 's/^.*Kraken version //; s/ .*\$//')
        pigz: \$( pigz --version 2>&1 | sed 's/pigz //g' )
    END_VERSIONS
    """
}
