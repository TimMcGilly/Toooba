BUILD_DIR="./../../builds/RV64ACDFIMSUxCHERI_Toooba_bluesim/build_dir"
bsc -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/Prefetcher_intf.bsv && \
bsc -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/InstructionPrefetchers.bsv && \
bsc -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/StridePrefetchers.bsv && \
bsc -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/MarkovPrefetchers.bsv && \
bsc -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/Prefetcher_top.bsv && \
bsc -bdir $BUILD_DIR -show-range-conflict -simdir $BUILD_DIR -sim -g mkStridePCPrefetcherTest ./../../src_Testbench/Unit/Prefetcher_test.bsv && bsc -bdir $BUILD_DIR -simdir $BUILD_DIR -sim -e mkStridePCPrefetcherTest -o prefetch_stridepc_test && \ 
./prefetch_stridepc_test && \
rm ./prefetch_stridepc_test*

