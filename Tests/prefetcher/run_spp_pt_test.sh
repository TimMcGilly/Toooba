BUILD_DIR="./../../builds/RV64ACDFIMSUxCHERI_Toooba_bluesim/build_dir"
FLAGS="+RTS -K16M -RTS" 
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/RWBramCore.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/Prefetcher_intf.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/InstructionPrefetchers.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/StridePrefetchers.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/MarkovPrefetchers.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/SignaturePathPrefetcher.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/coherence/src/prefetcher/Prefetcher_top.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -show-range-conflict -simdir $BUILD_DIR -sim -g mkPatternTableTest1 ./../../src_Testbench/Unit/SignaturePathPrefetcher_test.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR -sim -e mkPatternTableTest1 -o spp_pt_test1 && \
bsc $FLAGS -bdir $BUILD_DIR -show-range-conflict -simdir $BUILD_DIR -sim -g mkPatternTableTest2 ./../../src_Testbench/Unit/SignaturePathPrefetcher_test.bsv && \
bsc $FLAGS -bdir $BUILD_DIR -simdir $BUILD_DIR -sim -e mkPatternTableTest2 -o spp_pt_test2 && \
echo "---- Running test 1 ----"
./spp_pt_test1 && \
echo "---- Running test 2 ----"
./spp_pt_test2 && \
rm ./spp_pt_test*
