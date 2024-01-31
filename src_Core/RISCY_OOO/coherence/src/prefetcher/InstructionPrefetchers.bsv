// Copyright (c) 2023 Karlis Susters 
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

import Prefetcher_intf::*;
import Types::*;
import CacheUtils::*;
import CCTypes::*;
import ISA_Decls   :: *;
import ProcTypes::*;
import Vector::*;
import FIFO::*;
import Fifos::*;
import FIFOF::*;
import SpecialFIFOs :: *;
import Ehr::*;
import GetPut::*;
import RWBramCore::*;

`define VERBOSE False

module mkNextLineOnMissPrefetcher#(Parameter#(nextLinesOnMiss) _)(Prefetcher)
    provisos (
        Alias#(rqCntT, Bit#(TLog#(TAdd#(nextLinesOnMiss, 1)))),
        Add#(a__, TLog#(TAdd#(nextLinesOnMiss,1)), 64)
    );
    Reg#(Addr) lastMissAddr <- mkReg(0);
    Reg#(rqCntT) sentRequestCounter <- mkReg(fromInteger(valueOf(nextLinesOnMiss)));

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        if (hitMiss == HIT) begin
            if (`VERBOSE) $display("%t Prefetcher report HIT %h", $time, addr);
        end
        else begin
            if (`VERBOSE) $display("%t Prefetcher report MISS %h", $time, addr);
            lastMissAddr <= addr;
            sentRequestCounter <= 0;
        end
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if 
        (sentRequestCounter < fromInteger(valueOf(nextLinesOnMiss)));

        sentRequestCounter <= sentRequestCounter + 1;
        let addrToRequest = lastMissAddr + (zeroExtend(sentRequestCounter) + 1)*fromInteger(valueOf(DataSz));
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting %h", $time, addrToRequest);
        return addrToRequest;
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif
endmodule

module mkNextLineOnAllPrefetcher#(Parameter#(nextLinesOnAccess) _)(Prefetcher)
    provisos (
        Alias#(rqCntT, Bit#(TLog#(TAdd#(nextLinesOnAccess, 1)))),
        Add#(a__, TLog#(TAdd#(nextLinesOnAccess,1)), AddrSz)
    );
    Reg#(Addr) lastAccessAddr <- mkReg(0);
    Reg#(rqCntT) sentRequestCounter <- mkReg(fromInteger(valueOf(nextLinesOnAccess)));

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        if (hitMiss == HIT) begin
            if (`VERBOSE) $display("%t Prefetcher report HIT %h", $time, addr);
            lastAccessAddr <= addr;
            sentRequestCounter <= 0;
        end
        else begin
            if (`VERBOSE) $display("%t Prefetcher report MISS %h", $time, addr);
            lastAccessAddr <= addr;
            sentRequestCounter <= 0;
        end
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if 
        (sentRequestCounter < fromInteger(valueOf(nextLinesOnAccess)));

        sentRequestCounter <= sentRequestCounter + 1;
        let addrToRequest = lastAccessAddr + (zeroExtend(sentRequestCounter) + 1)*fromInteger(valueOf(DataSz));
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting %h", $time, addrToRequest);
        return addrToRequest;
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif
endmodule


module mkSingleWindowPrefetcher#(Parameter#(cacheLinesInRange) _)(Prefetcher);
    Integer cacheLinesInRange = valueOf(cacheLinesInRange);
    Reg#(LineAddr) rangeEnd <- mkReg(0); //Points to one CLine after end of range
    Reg#(LineAddr) nextToAsk <- mkReg(0);
    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        let cl = getLineAddr(addr);
        if (hitMiss == HIT && 
            rangeEnd - fromInteger(cacheLinesInRange) - 1 < cl && 
            cl < rangeEnd) begin

            let nextEnd = cl + fromInteger(cacheLinesInRange) + 1;
            if (`VERBOSE) $display("%t Prefetcher report HIT %h, moving window end to %h", $time, addr, Addr'{nextEnd, '0});
            rangeEnd <= nextEnd;
        end
        else if (hitMiss == MISS) begin
            if (`VERBOSE) $display("%t Prefetcher report MISS %h", $time, addr);
            //Reset window
            nextToAsk <= getLineAddr(addr) + 1;
            rangeEnd <= getLineAddr(addr) + fromInteger(cacheLinesInRange) + 1;
        end
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if (nextToAsk != rangeEnd);
        nextToAsk <= nextToAsk + 1;
        let retAddr = Addr'{nextToAsk, '0}; //extend cache line address to regular address
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting %h", $time, retAddr);
        return retAddr; 
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif
endmodule

module mkSingleWindowL1LLPrefetcher#(Parameter#(cacheLinesInRange) _)(Prefetcher);
    Integer cacheLinesInRange = valueOf(cacheLinesInRange);
    Reg#(LineAddr) rangeEnd <- mkReg(0); //Points to one CLine after end of range
    Reg#(LineAddr) nextToAsk <- mkReg(0);
    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        let cl = getLineAddr(addr);
        if (rangeEnd - fromInteger(cacheLinesInRange) - 1 <= cl && 
            cl < rangeEnd) begin

            let nextEnd = cl + fromInteger(cacheLinesInRange) + 1;
            if (`VERBOSE) $display("%t Prefetcher report HIT %h, moving window end to %h", $time, addr, Addr'{nextEnd, '0});
            rangeEnd <= nextEnd;
        end
        else if (hitMiss == MISS) begin
            if (`VERBOSE) $display("%t Prefetcher report MISS %h", $time, addr);
            //Reset window
            nextToAsk <= getLineAddr(addr) + 1;
            rangeEnd <= getLineAddr(addr) + fromInteger(cacheLinesInRange) + 1;
        end
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if (nextToAsk != rangeEnd);
        nextToAsk <= nextToAsk + 1;
        let retAddr = Addr'{nextToAsk, '0}; //extend cache line address to regular address
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting %h", $time, retAddr);
        return retAddr; 
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif
endmodule


typedef struct {
    LineAddr rangeEnd;
    LineAddr nextToAsk;
} StreamEntry deriving (Bits);

module mkMultiWindowPrefetcher#(Parameter#(numWindows) _, Parameter#(cacheLinesInRange) __)(Prefetcher)
provisos(
    Alias#(windowIdxT, Bit#(TLog#(numWindows)))
);
    Integer cacheLinesInRange = valueOf(cacheLinesInRange);
    Vector#(numWindows, Reg#(StreamEntry)) streams 
        <- replicateM(mkReg(StreamEntry {rangeEnd: '0, nextToAsk: '0}));
    Vector#(numWindows, Reg#(windowIdxT)) shiftReg <- genWithM(compose(mkReg, fromInteger));

    function Action moveWindowToFront(windowIdxT window) = 
    action
        if (shiftReg[0] == window) begin
        end
        else if (shiftReg[1] == window) begin
            shiftReg[0] <= window;
            shiftReg[1] <= shiftReg[0];
        end
        else if (shiftReg[2] == window) begin
            shiftReg[0] <= window;
            shiftReg[1] <= shiftReg[0];
            shiftReg[2] <= shiftReg[1];
        end
        else if (shiftReg[3] == window) begin
            shiftReg[0] <= window;
            shiftReg[1] <= shiftReg[0];
            shiftReg[2] <= shiftReg[1];
            shiftReg[3] <= shiftReg[2];
        end
    endaction;

    function ActionValue#(Maybe#(windowIdxT)) getMatchingWindow(Addr addr) = 
    actionvalue
        //Finds the first window that contains addr
        let cl = getLineAddr(addr);
        function Bool pred(StreamEntry se);
            return (se.rangeEnd - fromInteger(cacheLinesInRange) - 1 <= cl 
                && cl < se.rangeEnd);
        endfunction
        //Find first window that contains cache line cl
        if (findIndex(pred, readVReg(streams)) matches tagged Valid .idx) begin
            return Valid(pack(idx));
        end
        else begin
            return Invalid;
        end
    endactionvalue;

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        //Check if any stream line matches request
        //If so, advance that stream line and advance LRU shift reg
        //Otherwise if miss, allocate new stream line, and shift LRU reg completely,
        let idxMaybe <- getMatchingWindow(addr);
        if (idxMaybe matches tagged Valid .idx) begin
            moveWindowToFront(pack(idx)); //Update window as just used
            let newRangeEnd = getLineAddr(addr) + fromInteger(cacheLinesInRange) + 1;
            if (hitMiss == HIT) begin
                if (`VERBOSE) $display("%t Prefetcher report HIT %h, moving window end to %h for window idx %h", 
                    $time, addr, Addr'{newRangeEnd, '0}, idx);
                streams[idx].rangeEnd <= newRangeEnd;
            end
            else if (hitMiss == MISS) begin
                //Also reset nextToAsk on miss
                if (`VERBOSE) $display("%t Prefetcher report MISS %h, moving window end to %h for window idx %h", 
                    $time, addr, Addr'{newRangeEnd, '0}, idx);
                streams[idx] <= 
                    StreamEntry {nextToAsk: getLineAddr(addr) + 1, 
                                rangeEnd: newRangeEnd};
            end
        end
        else if (hitMiss == MISS) begin
            if (`VERBOSE) $display("%t Prefetcher report MISS %h, allocating new window, idx %h", $time, addr, shiftReg[3]);
            streams[shiftReg[3]] <= 
                StreamEntry {nextToAsk: getLineAddr(addr) + 1,
                            rangeEnd: getLineAddr(addr) + fromInteger(cacheLinesInRange) + 1};
            shiftReg[0] <= shiftReg[3];
            shiftReg[1] <= shiftReg[0];
            shiftReg[2] <= shiftReg[1];
            shiftReg[3] <= shiftReg[2];
        end
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr 
        if (streams[shiftReg[0]].nextToAsk != streams[shiftReg[0]].rangeEnd);

        streams[shiftReg[0]].nextToAsk <= streams[shiftReg[0]].nextToAsk + 1;
        let retAddr = Addr'{streams[shiftReg[0]].nextToAsk, '0}; //extend cache line address to regular address
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting %h from window idx %h", $time, retAddr, shiftReg[0]);
        return retAddr; 
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif

endmodule

module mkMultiWindowCrossCachePrefetcher#(Parameter#(numWindows) _, Parameter#(cacheLinesInRange) __)(Prefetcher)
provisos(
    Alias#(windowIdxT, Bit#(TLog#(numWindows)))
);
    Integer cacheLinesInRange = valueOf(cacheLinesInRange);
    Vector#(numWindows, Reg#(StreamEntry)) streams 
        <- replicateM(mkReg(StreamEntry {rangeEnd: '0, nextToAsk: '0}));
    Vector#(numWindows, Reg#(windowIdxT)) shiftReg <- genWithM(compose(mkReg, fromInteger));

    function Action moveWindowToFront(windowIdxT window) = 
    action
        if (shiftReg[0] == window) begin
        end
        else if (shiftReg[1] == window) begin
            shiftReg[0] <= window;
            shiftReg[1] <= shiftReg[0];
        end
        else if (shiftReg[2] == window) begin
            shiftReg[0] <= window;
            shiftReg[1] <= shiftReg[0];
            shiftReg[2] <= shiftReg[1];
        end
        else if (shiftReg[3] == window) begin
            shiftReg[0] <= window;
            shiftReg[1] <= shiftReg[0];
            shiftReg[2] <= shiftReg[1];
            shiftReg[3] <= shiftReg[2];
        end
    endaction;

    function ActionValue#(Maybe#(windowIdxT)) getMatchingWindow(Addr addr) = 
    actionvalue
        //Finds the first window that contains addr
        let cl = getLineAddr(addr);
        function Bool pred(StreamEntry se);
            return (se.rangeEnd - fromInteger(cacheLinesInRange) - 1 <= cl 
                && cl < se.rangeEnd);
        endfunction
        //Find first window that contains cache line cl
        if (findIndex(pred, readVReg(streams)) matches tagged Valid .idx) begin
            return Valid(pack(idx));
        end
        else begin
            return Invalid;
        end
    endactionvalue;

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        //Check if any stream line matches request
        //If so, advance that stream line and advance LRU shift reg
        //Otherwise if miss, allocate new stream line, and shift LRU reg completely,
        let idxMaybe <- getMatchingWindow(addr);
        if (idxMaybe matches tagged Valid .idx) begin
            moveWindowToFront(pack(idx)); //Update window as just used
            let newRangeEnd = getLineAddr(addr) + fromInteger(cacheLinesInRange) + 1;
            if (`VERBOSE) $display("%t Prefetcher report access %h, moving window end to %h for window idx %h", 
                $time, addr, Addr'{newRangeEnd, '0}, idx);
            streams[idx].rangeEnd <= newRangeEnd;
        end
        else if (hitMiss == MISS) begin
            //A miss in L1 is not necessarily a miss in L2, so this might create a window for lines already in L2
            if (`VERBOSE) $display("%t Prefetcher report MISS %h, allocating new window, idx %h", $time, addr, shiftReg[3]);
            streams[shiftReg[3]] <= 
                StreamEntry {nextToAsk: getLineAddr(addr) + 1,
                            rangeEnd: getLineAddr(addr) + fromInteger(cacheLinesInRange) + 1};
            shiftReg[0] <= shiftReg[3];
            shiftReg[1] <= shiftReg[0];
            shiftReg[2] <= shiftReg[1];
            shiftReg[3] <= shiftReg[2];
        end
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr 
        if (streams[shiftReg[0]].nextToAsk != streams[shiftReg[0]].rangeEnd);

        streams[shiftReg[0]].nextToAsk <= streams[shiftReg[0]].nextToAsk + 1;
        let retAddr = Addr'{streams[shiftReg[0]].nextToAsk, '0}; //extend cache line address to regular address
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting %h from window idx %h", $time, retAddr, shiftReg[0]);
        return retAddr; 
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif

endmodule