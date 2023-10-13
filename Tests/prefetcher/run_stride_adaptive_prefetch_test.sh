BUILD_DIR="./../../builds/RV64ACDFIMSUxCHERI_Toooba_bluesim/build_dir"
bsc -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/Prefetcher.bsv && \
bsc -bdir $BUILD_DIR -show-range-conflict -simdir $BUILD_DIR -sim -g mkStrideAdaptivePCPrefetcherTest ./../../src_Testbench/Unit/Prefetcher_test.bsv && bsc -bdir $BUILD_DIR -simdir $BUILD_DIR -sim -e mkStrideAdaptivePCPrefetcherTest -o prefetch_stride_adaptive_pc_test &&  \
./prefetch_stride_adaptive_pc_test && \
rm ./prefetch_stride_adaptive_pc_test*
