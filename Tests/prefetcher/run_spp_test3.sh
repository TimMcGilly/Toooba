BUILD_DIR="./../../builds/RV64ACDFIMSUxCHERI_Toooba_bluesim/build_dir"
FLAGS="+RTS -K16M -RTS" 
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/RWBramCore.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/Prefetcher_intf.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/InstructionPrefetchers.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/StridePrefetchers.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/MarkovPrefetchers.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/CheriPrefetchers.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/SignaturePathPrefetcher.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/Prefetcher_top.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -show-range-conflict -simdir $BUILD_DIR -sim -g mkSignaturePathPrefetcherTest3 ./../../src_Testbench/Unit/SignaturePathPrefetcher_test.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR -sim -e mkSignaturePathPrefetcherTest3 -o spp_test3 && \
echo "---- Running test 3 ----"
./spp_test3 && \
rm ./spp_test*
