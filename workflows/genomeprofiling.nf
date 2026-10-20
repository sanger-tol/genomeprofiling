/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// NF-CORE MODULE IMPORTS
include { FASTK_FASTK            } from '../modules/nf-core/fastk/fastk/main'
include { FASTK_HISTEX           } from '../modules/nf-core/fastk/histex/main'
include { GENOMESCOPE2           } from '../modules/nf-core/genomescope2/main'
include { SMUDGEPLOT_HETMERS     } from '../modules/local/smudgeplot/hetmers/main'
include { SMUDGEPLOT_ALL         } from '../modules/local/smudgeplot/all/main'

// SANGER-TOL SUBWORKFLOW IMPORTS
include { GENOME_STATISTICS      } from '../subworkflows/sanger-tol/genome_statistics/main'

// NF-CORE SUBWORKFLOW IMPORTS
include { FASTA_CLEAN_FAIDX      } from '../subworkflows/nf-core/fasta_clean_faidx/main'

include { paramsSummaryMap       } from 'plugin/nf-schema'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_genomeprofiling_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOMEPROFILING {

    take:
    ch_assemblies   // channel: [meta, [assemblies...]]
    outdir          // output directory

    main:

    def ch_versions = channel.empty()

    ch_data         = ch_assemblies
        .multiMap { meta, assemblies, reads ->
            // NOTE: BREAK DOWN THE LIST OF ASSEMBLIES INTO TUPLES OF (meta, assembly)
            assemblies: assemblies.withIndex().collect{ assembly, idx ->
                def new_meta = meta + [ idx: idx ]
                tuple(new_meta, file(assembly))
            }
            reads: tuple(meta, reads)
        }

    ch_assembly      = ch_data.assemblies.flatMap{it}


    //
    // SUBWORKFLOW: UNZIP, CLEAN AND INDEX THE ASSEMBLIES
    //
    FASTA_CLEAN_FAIDX(
        ch_assembly,
        false,
        true,
        true
    )


    //
    // MODULE: RUN FASTK FOR KMER COUNTS AND HISTS
    //
    FASTK_FASTK(
        ch_data.reads
    )


    //
    // MODULE: RUN FASTK HISTEX TO CONVERT .hist TO .txt
    //
    FASTK_HISTEX(
        FASTK_FASTK.out.hist.filter { _meta, _hist -> params.run_histex}
    )


    //
    // MODULE: RUN GENOMESCOPE2 TO GENERATE GENOME SCOPE PLOTS
    //
    GENOMESCOPE2(
        FASTK_HISTEX.out.hist.filter { _meta, _hist -> params.run_genomescope}
    )


    //
    // MODULE: RUN HETMERS TO COLLECT DATA NEEDED FOR SMUDGEPLOT
    //
    SMUDGEPLOT_HETMERS(
        FASTK_FASTK.out.ktab
    )


    //
    // MODULE: RUN SMUDGEPLOT ALL TO GENERATE THE SMUDGEPLOT GRAPHS
    //
    SMUDGEPLOT_ALL(
        SMUDGEPLOT_HETMERS.out.kmer_cov
    )


    //
    // LOGIC: SETUP CHANNEL FOR GENOME_STATISTICS AND MERQURYFK_PLOIDYPLOT
    //
    def fastk_data = FASTK_FASTK.out.hist
        .combine(FASTK_FASTK.out.ktab, by: 0)
        .map { meta, hist, ktab_list ->
            tuple(meta, hist, ktab_list)
        }


    def assembly_data = FASTA_CLEAN_FAIDX.out.reference
        .map { meta, fasta ->
            def new_meta = meta - meta.subMap(['idx'])
            tuple(new_meta, meta.idx, fasta)
        }
        .groupTuple(by: 0)
        .map { meta_base, indices, fastas ->
            // Sort by index
            def sorted = [indices, fastas].transpose()
                .sort { it[0] }
                .collect { it[1] }
            tuple(meta_base, sorted)
        }


    //
    // SUBWORKFLOW: GENOMESTATISTICS RUNS ASMSTATS AND GFSTATS
    //              BUSCO WILL NOT BE USED FOR THIS CONTEXT
    //
    GENOME_STATISTICS(
        assembly_data,
        fastk_data.map{ meta, hist, ktab_list ->
            tuple(meta, hist, ktab_list, [], [])
        },
        channel.empty(),
        channel.empty()
    )


    //
    // Collate and save software versions
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name:  'genomeprofiling_software_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    emit:
    gs_stats                    = GENOME_STATISTICS.out.stats
    gs_asmstats                 = GENOME_STATISTICS.out.asmstats
    gs_gfastats                 = GENOME_STATISTICS.out.gfastats
    gs_merqury                  = GENOME_STATISTICS.out.merqury
    gs_merqury_qv               = GENOME_STATISTICS.out.merqury_qv
    gs_merqury_completeness     = GENOME_STATISTICS.out.merqury_completeness
    gs_merqury_phased_stats     = GENOME_STATISTICS.out.merqury_phased_stats
    gs_merqury_images           = GENOME_STATISTICS.out.merqury_images
    fastk_ktabs                 = FASTK_FASTK.out.ktab
    fastk_hist                  = FASTK_FASTK.out.hist
    genomescope_lin_plot        = GENOMESCOPE2.out.linear_plot_png
    genomescope_trans_lin_plot  = GENOMESCOPE2.out.transformed_linear_plot_png
    genomescope_log_plot        = GENOMESCOPE2.out.log_plot_png
    genomescope_trans_log_plot  = GENOMESCOPE2.out.transformed_log_plot_png
    genomescope_model           = GENOMESCOPE2.out.model
    genomescope_summary         = GENOMESCOPE2.out.summary
    genomescope_json_report     = GENOMESCOPE2.out.json_report
    smudgeplot_report           = SMUDGEPLOT_ALL.out.smudge_report
    smudgeplot_png              = SMUDGEPLOT_ALL.out.png
    smudgeplot_centrality_txt   = SMUDGEPLOT_ALL.out.centrality_txt

    versions                    = ch_collated_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
