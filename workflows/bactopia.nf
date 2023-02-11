#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

/*
========================================================================================
    CONFIG FILES
========================================================================================
*/
include { create_input_channel; check_input_fofn; setup_datasets } from '../lib/nf/bactopia'
include { get_resources; get_schemas; print_efficiency } from '../lib/nf/functions'
RESOURCES = get_resources(workflow.profile, params.max_memory, params.max_cpus)

/*
========================================================================================
    VALIDATE INPUTS
========================================================================================
*/
SCHEMAS = get_schemas()
WorkflowMain.initialise(workflow, params, log, schema_filename=SCHEMAS)
run_type = WorkflowBactopia.initialise(workflow, params, log, schema_filename=SCHEMAS)

if (params.check_samples) {
    check_input_fofn()
}

/*
========================================================================================
    IMPORT LOCAL MODULES/SUBWORKFLOWS
========================================================================================
*/

// Core

include { AMRFINDERPLUS } from '../subworkflows/local/amrfinderplus/main';
include { ASSEMBLER } from '../modules/local/bactopia/assembler/main'
//include { ASSEMBLY_QC } from '../modules/local/bactopia/assembly_qc/main'
include { GATHER } from '../modules/local/bactopia/gather/main'
include { SKETCHER } from '../modules/local/bactopia/sketcher/main'
include { MLST } from '../subworkflows/local/mlst/main';
include { QC } from '../modules/local/bactopia/qc/main'

// Annotation wih Bakta or Prokka
if (params.use_bakta) {
    include { BAKTA_MAIN as ANNOTATOR } from '../subworkflows/local/bakta/main'
} else {
    include { PROKKA_MAIN as ANNOTATOR } from '../subworkflows/local/prokka/main'
}

// Require Datasets
//include { MINMER_QUERY } from '../modules/local/bactopia/minmer_query/main'

// Merlin
if (params.ask_merlin) include { MERLIN } from '../subworkflows/local/merlin/main';

/*
========================================================================================
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
========================================================================================
*/

include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main' addParams( options: [publish_to_base: true] )

/*
========================================================================================
    RUN MAIN WORKFLOW
========================================================================================
*/
ADAPTERS = params.adapters ? file(params.adapters) : file(params.empty_adapters)
PHIX = params.phix ? file(params.phix) : file(params.empty_phix)
PROTEINS = params.proteins ? file(params.proteins) : file(params.empty_proteins)
PRODIGAL_TF = params.prodigal_tf ? file(params.prodigal_tf) : file(params.empty_tf)

workflow BACTOPIA {
    print_efficiency(RESOURCES.MAX_CPUS) 
    datasets = setup_datasets()
    ch_versions = Channel.empty()

    // Core steps
    GATHER(create_input_channel(run_type, datasets['genome_size']))
    QC(GATHER.out.raw_fastq.combine(Channel.fromPath(ADAPTERS)).combine(Channel.fromPath(PHIX)))
    SKETCHER(QC.out.fastq)
    ASSEMBLER(QC.out.fastq_assembly)
    //ASSEMBLY_QC(ASSEMBLE_GENOME.out.fna)
    ANNOTATOR(ASSEMBLER.out.fna.combine(Channel.fromPath(PROTEINS)).combine(Channel.fromPath(PRODIGAL_TF)))
    AMRFINDERPLUS(ANNOTATOR.out.annotations)
    MLST(ASSEMBLER.out.fna_only)

    if (params.ask_merlin) {
        MERLIN(ASSEMBLER.out.fna_fastq)
        ch_versions = ch_versions.mix(MERLIN.out.versions)
    }

    // Collect Versions
    ch_versions = ch_versions.mix(GATHER.out.versions.first())
    ch_versions = ch_versions.mix(QC.out.versions.first())
    ch_versions = ch_versions.mix(ASSEMBLER.out.versions.first())
    //ch_versions = ch_versions.mix(ASSEMBLY_QC.out.versions.first())
    ch_versions = ch_versions.mix(ANNOTATOR.out.versions.first())
    ch_versions = ch_versions.mix(SKETCHER.out.versions.first())
    ch_versions = ch_versions.mix(AMRFINDERPLUS.out.versions.first())
    ch_versions = ch_versions.mix(MLST.out.versions.first())
    CUSTOM_DUMPSOFTWAREVERSIONS(ch_versions.unique().collectFile())
}

/*
========================================================================================
    COMPLETION EMAIL AND SUMMARY
========================================================================================
*/
workflow.onComplete {
    workDir = new File("${workflow.workDir}")

    println """
    Bactopia Execution Summary
    ---------------------------
    Bactopia Version : ${workflow.manifest.version}
    Nextflow Version : ${nextflow.version}
    Command Line     : ${workflow.commandLine}
    Resumed          : ${workflow.resume}
    Completed At     : ${workflow.complete}
    Duration         : ${workflow.duration}
    Success          : ${workflow.success}
    Exit Code        : ${workflow.exitStatus}
    Error Report     : ${workflow.errorReport ?: '-'}
    Launch Dir       : ${workflow.launchDir}
    """
}

/*
========================================================================================
    THE END
========================================================================================
*/
