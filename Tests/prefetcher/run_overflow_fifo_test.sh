BUILD_DIR="./../../builds/RV64ACDFIMSUxCHERI_Toooba_bluesim/build_dir"
bsc -p +:./../../src_Core/RISCY_OOO/procs/RV64G_OOO  -bdir $BUILD_DIR -simdir $BUILD_DIR ./../../src_Core/RISCY_OOO/procs/lib/Fifos.bsv && \
bsc -bdir $BUILD_DIR -show-range-conflict -simdir $BUILD_DIR -sim -g mkOverflowPipelineFifoTest ./../../src_Testbench/Unit/Prefetcher_test.bsv && bsc -bdir $BUILD_DIR -simdir $BUILD_DIR -sim -e mkOverflowPipelineFifoTest -o overflow_fifo_test && \ 
./overflow_fifo_test && \
rm ./overflow_fifo_test*
