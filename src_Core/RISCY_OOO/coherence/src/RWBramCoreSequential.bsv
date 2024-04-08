
// Copyright (c) 2024 Karlis Susters
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import BRAMCore::*;
import Fifos::*;
import Vector::*;

//When reading for idx, returns entries idx, idx+1, ...idx+seqLen-1 together
//Idx doesn't have to be aligned
interface RWBramCoreSequential#(numeric type addrWidth, type dataT, numeric type seqLen);
    method Action wrReq(Bit#(addrWidth) a, dataT d);
    method Action rdReq(Bit#(addrWidth) a);
    method Vector#(seqLen, dataT) rdResp;
    method Bool rdRespValid;
    method Action deqRdResp;
endinterface

module mkRWBramCoreSequential(RWBramCoreSequential#(addrSz, dataT, seqLen)) provisos(
    Bits#(dataT, dataSz),
    Alias#(addrT, Bit#(addrSz)),
    NumAlias#(innerAddrSz, TSub#(addrSz, TLog#(seqLen))),
    Alias#(innerAddrT, Bit#(innerAddrSz)),
    Alias#(bramSelector, Bit#(TLog#(seqLen))),
    Add#(a__, TLog#(seqLen), addrSz)
);
    Vector#(seqLen, BRAM_DUAL_PORT#(innerAddrT, dataT)) bram <- replicateM(mkBRAMCore2(valueOf(TExp#(innerAddrSz)), False));
    function BRAM_PORT#(innerAddrT, dataT) getWrPort (Integer x) = bram[x].a;
    Vector#(seqLen, BRAM_PORT#(innerAddrT, dataT)) wrPorts = genWith(getWrPort);
    function BRAM_PORT#(innerAddrT, dataT) getRdPort (Integer x) = bram[x].b;
    Vector#(seqLen, BRAM_PORT#(innerAddrT, dataT)) rdPorts = genWith(getRdPort);
    // 1 elem pipeline fifo to add guard for read req/resp
    // must be 1 elem to make sure rdResp is not corrupted
    // BRAMCore should not change output if no req is made
    Fifo#(1, bramSelector) rdReqFirstBram <- mkPipelineFifo;

    method Action wrReq(addrT a, dataT d);
        innerAddrT ia = truncateLSB(a);
        bramSelector bs = truncate(a);
        $display ("WRREq %h %h", ia, bs);
        wrPorts[bs].put(True, ia, d);
    endmethod

    method Action rdReq(addrT a);
        bramSelector firstBram = truncate(a);
        function innerAddrT genInnerAddr(Integer x) = truncateLSB(a+fromInteger(x));
        Vector#(seqLen, innerAddrT) lookupAddrs = rotateBy(genWith(genInnerAddr), unpack(firstBram));
        $display("rd req", fshow(lookupAddrs));
        rdReqFirstBram.enq(truncate(a));
        for (Integer x = 0; x < valueOf(seqLen); x = x + 1) begin
            rdPorts[x].put(False, lookupAddrs[x], ?);
        end
    endmethod

    method Vector#(seqLen, dataT) rdResp if(rdReqFirstBram.notEmpty);
        bramSelector firstBram = rdReqFirstBram.first;
        //$display("rdresp %h", firstBram);
        function dataT getData(Integer i);
            //bramselector should naturally overflow
            bramSelector idx = (fromInteger(i)+firstBram);
            return rdPorts[idx].read;
        endfunction
        Vector#(seqLen, dataT) res = genWith(getData);
        return res;
    endmethod

    method rdRespValid = rdReqFirstBram.notEmpty;

    method Action deqRdResp;
        rdReqFirstBram.deq;
    endmethod
endmodule
