#! /usr/bin/env nextflow
PROGRAM_NAME = workflow.manifest.name
VERSION = workflow.manifest.version
OUTDIR = "${params.outdir}/bactopia-tools/${PROGRAM_NAME}/${params.prefix}"
DOWNLOAD_GTDB = false
OVERWRITE = workflow.resume || params.force ? true : false

// Validate parameters
if (params.version) print_version();
log.info "bactopia tools ${PROGRAM_NAME} - ${VERSION}"
if (params.help || workflow.commandLine.trim().endsWith(workflow.scriptName)) print_help();
check_input_params()
samples = gather_sample_set(params.bactopia, params.exclude, params.include, params.sleep_time)

process download_gtdb {
    input:
    env GTDBTK_DATA_PATH from params.gtdb

    output:
    file 'gtdb-downloaded.txt' into GTDB_CHECK

    shell:
    """
    if [ "!{DOWNLOAD_GTDB}" == "true" ]; then
        rm -rf !{params.gtdb}/gtdbtk_data.tar.gz
        download-db.sh
    else
        echo "skipping GTDB database download"
    fi

    touch gtdb-downloaded.txt
    """
}

process check_gtdb {
    input:
    file(gtdb) from GTDB_CHECK
    env GTDBTK_DATA_PATH from params.gtdb

    output:
    file 'gtdb-passed.txt' into GTDB

    shell:
    """
    gtdbtk check_install && touch gtdb-passed.txt
    """
}

process gtdb {
    publishDir OUTDIR, mode: 'copy', overwrite: OVERWRITE, pattern: "classify/*"
    
    input:
    file(fasta) from Channel.fromList(samples).collect()
    file(gtdb) from GTDB
    env GTDBTK_DATA_PATH from params.gtdb

    output:
    file 'classify/*' into ANNOTATE

    shell:
    debug = params.debug ? "--debug" : ""
    recalculate_red = params.recalculate_red ? "--recalculate_red" : ""
    force = params.force_gtdb ? "--force" : ""
    """
    mkdir genomes
    find . -name "*.fna.gz" | xargs -I {} gunzip {}
    cp -P *.fna genomes/
    gtdbtk classify_wf !{debug} !{recalculate_red} !{force} \
        --cpus !{task.cpus} \
        --genome_dir ./genomes \
        --out_dir classify \
        --min_perc_aa !{params.min_perc_aa} \
        --prefix !{params.prefix}
    """
}

workflow.onComplete {
    workDir = new File("${workflow.workDir}")
    workDirSize = toHumanString(workDir.directorySize())

    println """
    Bactopia Tool '${PROGRAM_NAME}' - Execution Summary
    ---------------------------
    Command Line    : ${workflow.commandLine}
    Resumed         : ${workflow.resume}
    Completed At    : ${workflow.complete}
    Duration        : ${workflow.duration}
    Success         : ${workflow.success}
    Exit Code       : ${workflow.exitStatus}
    Error Report    : ${workflow.errorReport ?: '-'}
    Launch Dir      : ${workflow.launchDir}
    Working Dir     : ${workflow.workDir} (Total Size: ${workDirSize})
    Working Dir Size: ${workDirSize}
    """
}

// Utility functions
def toHumanString(bytes) {
    // Thanks Niklaus
    // https://gist.github.com/nikbucher/9687112
    base = 1024L
    decimals = 3
    prefix = ['', 'K', 'M', 'G', 'T']
    int i = Math.log(bytes)/Math.log(base) as Integer
    i = (i >= prefix.size() ? prefix.size()-1 : i)
    return Math.round((bytes / base**i) * 10**decimals) / 10**decimals + prefix[i]
}

def print_version() {
    log.info "bactopia tools ${PROGRAM_NAME} - ${VERSION}"
    exit 0
}

def file_exists(file_name, parameter) {
    if (!file(file_name).exists()) {
        log.error('Invalid input ('+ parameter +'), please verify "' + file_name + '" exists.')
        return 1
    }
    return 0
}

def output_exists(outdir, force, resume) {
    if (!resume && !force) {
        if (file(OUTDIR).exists()) {
            files = file(OUTDIR).list()
            total_files = files.size()
            if (total_files == 1) {
                if (files[0] != 'bactopia-info') {
                    return 1
                }
            } else if (total_files > 1){
                return 1
            }
        }
    }
    return 0
}

def check_unknown_params() {
    valid_params = []
    error = 0
    new File("${baseDir}/conf/params.config").eachLine { line ->
        if (line.contains("=")) {
            valid_params << line.trim().split(" ")[0]
        }
    }

    IGNORE_LIST = ['container-path']
    params.each { k,v ->
        if (!valid_params.contains(k)) {
            if (!IGNORE_LIST.contains(k)) {
                log.error("'--${k}' is not a known parameter")
                error = 1
            }
        }
    }

    return error
}

def check_input_params() {
    // Check for unexpected paramaters
    error = check_unknown_params()

    mising_required = false
    if (!params.bactopia || !params.gtdb) {
        log.error """
        The required parameter(s) '--bactopia' and/or '--gtdb'are missing, please check and try again.

        Required Parameters:
            --bactopia STR          Directory containing Bactopia analysis results for all samples.

            --gtdb STR              Location of a GTDB database. If a database is not found, it will
                                        be downloaded.
        """.stripIndent()
        error += 1
    }

    error += file_exists(params.bactopia, '--bactopia')
    if (file(params.gtdb).exists() && params.download_gtdb) {
        log.info """
            Found GTDB database at ${params.gtdb}, but '--download_gtdb'
            also given. Existing GTDB database will be over written with
            latest build. If this is error, please stop now.
        """.stripIndent()
        DOWNLOAD_GTDB = true
    } else if (!file(params.gtdb).exists() && params.download_gtdb) {
        log.info("Latest GTDB database will be downloaded to ${params.gtdb}")
        DOWNLOAD_GTDB = true
    } else if (!file(params.gtdb).exists()) {
        log.error """
            Please check that a GTDB database exists at ${params.gtdb}. 
            Otherwise use '--download_gtdb' to download the latest GTDB database
        """.stripIndent()
        error += 1
    }

    if (params.include) {
        error += file_exists(params.include, '--include')
    }
    
    if (params.exclude) {
        error += file_exists(params.exclude, '--exclude')
    } 

    error += is_positive_integer(params.cpus, 'cpus')
    error += is_positive_integer(params.max_time, 'min_time')
    error += is_positive_integer(params.max_time, 'max_time')
    error += is_positive_integer(params.max_memory, 'max_memory')
    error += is_positive_integer(params.sleep_time, 'sleep_time')
    error += is_positive_integer(params.min_perc_aa, 'min_perc_aa')

    // Check for existing output directory
    if (output_exists(OUTDIR, params.force, workflow.resume)) {
        log.error("Output directory (${OUTDIR}) exists, Bactopia will not continue unless '--force' is used.")
        error += 1
    }

    if (!['dockerhub', 'github', 'quay'].contains(params.registry)) {
        log.error "Invalid registry (--registry ${params.registry}), must be 'dockerhub', " +
                    "'github' or 'quay'. Please correct to continue."
        error += 1
    }

    if (params.min_time > params.max_time) {
        log.error "The value for min_time (${params.min_time}) exceeds max_time (${params.max_time}), Please correct to continue."
        error += 1
    }

    // Check publish_mode
    ALLOWED_MODES = ['copy', 'copyNoFollow', 'link', 'rellink', 'symlink']
    if (!ALLOWED_MODES.contains(params.publish_mode)) {
        log.error("'${params.publish_mode}' is not a valid publish mode. Allowed modes are: ${ALLOWED_MODES}")
        error += 1
    }

    if (error > 0) {
        log.error('Cannot continue, please see --help for more information')
        exit 1
    }
}

def is_positive_integer(value, name) {
    error = 0
    if (value.getClass() == Integer) {
        if (value < 0) {
            log.error('Invalid input (--'+ name +'), "' + value + '"" is not a positive integer.')
            error = 1
        }
    } else {
        if (!value.isInteger()) {
            log.error('Invalid input (--'+ name +'), "' + value + '"" is not numeric.')
            error = 1
        } else if (value.toInteger() < 0) {
            log.error('Invalid input (--'+ name +'), "' + value + '"" is not a positive integer.')
            error = 1
        }
    }
    return error
}

def is_sample_dir(sample, dir){
    return file("${dir}/${sample}/${sample}-genome-size.txt").exists()
}

def build_assembly_tuple(sample, dir) {
    assembly = "${dir}/${sample}/assembly/${sample}.fna"
    if (file("${assembly}.gz").exists()) {
        // Compressed assemblies
        return file("${assembly}.gz")
    } else if (file(assembly).exists()) {
        return file(assembly)
    } else {
        log.error("Could not locate assembly for ${sample}, please verify existence. Unable to continue.")
        exit 1
    }
}

def gather_sample_set(bactopia_dir, exclude_list, include_list, sleep_time) {
    include_all = true
    inclusions = []
    exclusions = []
    IGNORE_LIST = ['.nextflow', 'bactopia-info', 'bactopia-tools', 'work',]
    if (include_list) {
        new File(include_list).eachLine { line -> 
            inclusions << line.trim().split('\t')[0]
        }
        include_all = false
        log.info "Including ${inclusions.size} samples for analysis"
    }
    else if (exclude_list) {
        new File(exclude_list).eachLine { line -> 
            exclusions << line.trim().split('\t')[0]
        }
        log.info "Excluding ${exclusions.size} samples from the analysis"
    }
    
    sample_list = []
    file(bactopia_dir).eachFile { item ->
        if( item.isDirectory() ) {
            sample = item.getName()
            if (!IGNORE_LIST.contains(sample)) {
                if (inclusions.contains(sample) || include_all) {
                    if (!exclusions.contains(sample)) {
                        if (is_sample_dir(sample, bactopia_dir)) {
                            sample_list << build_assembly_tuple(sample, bactopia_dir)
                        } else {
                            log.info "${sample} is missing genome size estimate file"
                        }
                    }
                }
            }
        }
    }

    log.info "Found ${sample_list.size} samples to process"
    log.info "\nIf this looks wrong, now's your chance to back out (CTRL+C 3 times)."
    log.info "Sleeping for ${sleep_time} seconds..."
    sleep(sleep_time * 1000)
    return sample_list
}

def print_help() {
    log.info"""
    Required Parameters:
        --bactopia STR          Directory containing Bactopia analysis results for all samples.

        --gtdb STR              Location of a GTDB database. Due to the size of GTDB (>30GB), you must
                                    also provide '--download_gtdb' if you would like to download GTDB
                                    automatically.

    Optional Parameters:
        --include STR           A text file containing sample names to include in the
                                    analysis. The expected format is a single sample per line.

        --exclude STR           A text file containing sample names to exclude from the
                                    analysis. The expected format is a single sample per line.

        --prefix DIR            Prefix to use for final output files
                                    Default: ${params.prefix}

        --outdir DIR            Directory to write results to
                                    Default: ${params.outdir}

        --min_time INT          The minimum number of minutes a job should run before being halted.
                                    Default: ${params.min_time} minutes

        --max_time INT          The maximum number of minutes a job should run before being halted.
                                    Default: ${params.max_time} minutes

        --max_memory INT        The maximum amount of memory (Gb) allowed to a single process.
                                    Default: ${params.max_memory} Gb

        --cpus INT              Number of processors made available to a single
                                    process.
                                    Default: ${params.cpus}

    GTDB-Tk Related Parameters:
        --download_gtdb         Download the latest GTDB database, even it exists.

        --min_perc_aa INT       Filter genomes with an insufficient percentage of AA in the MSA
                                    Default: ${params.min_perc_aa}

        --recalculate_red       Recalculate RED values based on the reference tree and all added 
                                    user genomes

        --force_gtdb            Force GTDB to continue processing if an error occurrs on a single
                                    genome

        --debug                 Create intermediate files for debugging purposes

    Nextflow Related Parameters:
        --condadir DIR          Directory to Nextflow should use for Conda environments
                                    Default: Bactopia's Nextflow directory

        --registry STR          Docker registry to pull containers from. 
                                    Available options: dockerhub, quay, or github
                                    Default: dockerhub

        --singularity_cache STR Directory where remote Singularity images are stored. If using a cluster, it must
                                    be accessible from all compute nodes.
                                    Default: NXF_SINGULARITY_CACHEDIR evironment variable, otherwise ${params.singularity_cache}

        --queue STR             The name of the queue(s) to be used by a job scheduler (e.g. AWS Batch or SLURM).
                                    If using multiple queues, please seperate queues by a comma without spaces.
                                    Default: ${params.queue}

        --disable_scratch       All intermediate files created on worker nodes of will be transferred to the head node.
                                    Default: Only result files are transferred back

        --cleanup_workdir       After Bactopia is successfully executed, the work directory will be deleted.
                                    Warning: by doing this you lose the ability to resume workflows.

        --publish_mode          Set Nextflow's method for publishing output files. Allowed methods are:
                                    'copy' (default)    Copies the output files into the published directory.

                                    'copyNoFollow' Copies the output files into the published directory 
                                                   without following symlinks ie. copies the links themselves.

                                    'link'    Creates a hard link in the published directory for each 
                                              process output file.

                                    'rellink' Creates a relative symbolic link in the published directory
                                              for each process output file.

                                    'symlink' Creates an absolute symbolic link in the published directory 
                                              for each process output file.

                                    Default: ${params.publish_mode}

        --force                 Nextflow will overwrite existing output files.
                                    Default: ${params.force}

        --sleep_time            After reading datases, the amount of time (seconds) Nextflow
                                    will wait before execution.
                                    Default: ${params.sleep_time} seconds

        --nfconfig STR          A Nextflow compatible config file for custom profiles. This allows 
                                    you to create profiles specific to your environment (e.g. SGE,
                                    AWS, SLURM, etc...). This config file is loaded last and will 
                                    overwrite existing variables if set.
                                    Default: Bactopia's default configs

        -resume                 Nextflow will attempt to resume a previous run. Please notice it is 
                                    only a single '-'

    AWS Batch Related Parameters:
        --aws_region STR        AWS Region to be used by Nextflow
                                    Default: ${params.aws_region}

        --aws_volumes STR       Volumes to be mounted from the EC2 instance to the Docker container
                                    Default: ${params.aws_volumes}

        --aws_cli_path STR       Path to the AWS CLI for Nextflow to use.
                                    Default: ${params.aws_cli_path}

        --aws_upload_storage_class STR
                                The S3 storage slass to use for storing files on S3
                                    Default: ${params.aws_upload_storage_class}

        --aws_max_parallel_transfers INT
                                The number of parallele transfers between EC2 and S3
                                    Default: ${params.aws_max_parallel_transfers}

        --aws_delay_between_attempts INT
                                The duration of sleep (in seconds) between each transfer between EC2 and S3
                                    Default: ${params.aws_delay_between_attempts}

        --aws_max_transfer_attempts INT
                                The maximum number of times to retry transferring a file between EC2 and S3
                                    Default: ${params.aws_max_transfer_attempts}

        --aws_max_retry INT     The maximum number of times to retry a process on AWS Batch
                                    Default: ${params.aws_max_retry}

        --aws_ecr_registry STR  The ECR registry containing Bactopia related containers.
                                    Default: Use the registry given by --registry 

    Useful Parameters:
        --version               Print workflow version information
        --help                  Show this message and exit
    """.stripIndent()
    exit 0
}
