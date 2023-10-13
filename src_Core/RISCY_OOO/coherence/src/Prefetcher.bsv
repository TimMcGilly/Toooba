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

import ISA_Decls   :: *;
import CrossBar::*;
import GetPut::*;
import RWBramCore::*;
import FIFO::*;
import Fifos::*;
import FIFOF::*;
import SpecialFIFOs :: *;
import Ehr::*;
import CacheUtils::*;
import CCTypes::*;
import Types::*;
import Vector::*;
import BuildVector::*;
import ProcTypes::*;

`define VERBOSE False

typedef enum {
    HIT = 1'b0, MISS = 1'b1
} HitOrMiss deriving (Bits, Eq, FShow);

interface Prefetcher;
    (* always_ready *)
    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
    method ActionValue#(Addr) getNextPrefetchAddr();
endinterface

interface PCPrefetcher;
    (* always_ready *)
    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
    method ActionValue#(Addr) getNextPrefetchAddr();
endinterface

module mkDoNothingPrefetcher(Prefetcher);
    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if (False);
        return 64'h0;
    endmethod
endmodule

module mkAlwaysRequestPrefetcher(Prefetcher);
    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr;
        return 64'h8000ff00;
    endmethod
endmodule

module mkPrintPrefetcher(Prefetcher);
    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        if (hitMiss == HIT) begin
            if (`VERBOSE) $display("%t PrintPrefetcher report HIT %h", $time, addr);
        end
        else begin
            if (`VERBOSE) $display("%t PrintPrefetcher report MISS %h", $time, addr);
        end
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if (False);
        return 64'h0;
    endmethod
endmodule


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

endmodule

typedef struct {
    Bit#(tagBits) tag;
    Bit#(distanceBits) distance;
} NarrowTargetEntry#(numeric type tagBits, numeric type distanceBits) deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(tagBits) tag;
    LineAddr target;
} WideTargetEntry#(numeric type tagBits) deriving (Bits, Eq, FShow);


interface TargetTable#(numeric type narrowTableSize, numeric type wideTableSize);
    method Action writeReq(LineAddr prevAddr, LineAddr currAddr);
    method Action readReq(LineAddr addr);
    method ActionValue#(Maybe#(LineAddr)) readResp();
endinterface

module mkTargetTable(TargetTable#(narrowTableSize, wideTableSize)) provisos
(
    NumAlias#(narrowTableIdxBits, TLog#(narrowTableSize)),
    NumAlias#(wideTableIdxBits, TLog#(wideTableSize)),
    NumAlias#(narrowTableTagBits, TSub#(24, narrowTableIdxBits)),
    NumAlias#(wideTableTagBits, TSub#(24, wideTableIdxBits)),
    NumAlias#(narrowDistanceBits, 4),
    NumAlias#(narrowMaxDistanceAbs, TExp#(TSub#(narrowDistanceBits, 1))),
    Alias#(narrowTargetEntryT, NarrowTargetEntry#(narrowTableTagBits, narrowDistanceBits)),
    Alias#(wideTargetEntryT, WideTargetEntry#(wideTableTagBits)),
    Add#(a__, TLog#(narrowTableSize), 32),
    Add#(b__, TLog#(narrowTableSize), 58),
    Add#(c__, TLog#(wideTableSize), 32),
    Add#(d__, TLog#(wideTableSize), 58)
);
    RWBramCore#(Bit#(narrowTableIdxBits), Maybe#(narrowTargetEntryT)) narrowTable <- mkRWBramCore;
    RWBramCore#(Bit#(wideTableIdxBits), Maybe#(wideTargetEntryT)) wideTable <- mkRWBramCore;
    Reg#(LineAddr) readReqLineAddr <- mkReg(?); 

    method Action writeReq(LineAddr prevAddr, LineAddr currAddr);
        let distance = currAddr - prevAddr;
        Bit#(32) prevAddrHash = hash(prevAddr);
        if (abs(distance) < fromInteger(valueOf(narrowMaxDistanceAbs))) begin
            //Store in narrow table
            narrowTargetEntryT entry;
            entry.tag = prevAddrHash[23:valueOf(narrowTableIdxBits)];
            entry.distance = truncate(distance);
            Bit#(narrowTableIdxBits) idx = truncate(prevAddrHash);
            narrowTable.wrReq(idx, tagged Valid entry);
        end
        else begin
            //Store in wide table
            wideTargetEntryT entry;
            entry.tag = prevAddrHash[23:valueOf(wideTableIdxBits)];
            entry.target = currAddr;
            Bit#(wideTableIdxBits) idx = truncate(prevAddrHash);
            wideTable.wrReq(idx, tagged Valid entry);
        end
    endmethod

    method Action readReq(LineAddr addr);
        Bit#(32) addrHash = hash(addr);
        Bit#(narrowTableIdxBits) narrowIdx = truncate(addrHash);
        narrowTable.rdReq(narrowIdx);
        Bit#(wideTableIdxBits) wideIdx = truncate(addrHash);
        wideTable.rdReq(wideIdx);
        readReqLineAddr <= addr;
    endmethod

    method ActionValue#(Maybe#(LineAddr)) readResp();
        // Returns the read response and if a table had a hit, 
        // sends a write request to clear the entry in that table
        narrowTable.deqRdResp;
        wideTable.deqRdResp;
        let addr = readReqLineAddr;
        Bit#(32) addrHash = hash(addr);
        Bit#(narrowTableIdxBits) narrowIdx = truncate(addrHash);
        Bit#(wideTableIdxBits) wideIdx = truncate(addrHash);
        if (narrowTable.rdResp matches tagged Valid .entry 
            &&& entry.tag == addrHash[23:valueOf(narrowTableIdxBits)]) begin
            if (`VERBOSE) $display("%t found narrow table entry %h", $time, addr + signExtend(pack(entry.distance)));
            return Valid(addr + signExtend(pack(entry.distance)));
        end
        else if (wideTable.rdResp matches tagged Valid .entry 
            &&& entry.tag == addrHash[23:valueOf(wideTableIdxBits)]) begin
            if (`VERBOSE) $display("%t found wide table entry %h", $time, entry.target);
            return Valid(entry.target);
        end
        else begin
            return Invalid;
        end
        
    endmethod
endmodule

interface TargetTableDouble#(numeric type narrowTableSize, numeric type wideTableSize);
    method Action sendReadWriteReq(LineAddr addr, HitOrMiss hitMiss);
    method ActionValue#(Tuple2#(Maybe#(LineAddr), Maybe#(LineAddr))) readResp();
endinterface

module mkTargetTableDouble(TargetTableDouble#(narrowTableSize, wideTableSize)) provisos
(
    NumAlias#(narrowTableIdxBits, TLog#(narrowTableSize)),
    NumAlias#(wideTableIdxBits, TLog#(wideTableSize)),
    NumAlias#(narrowTableTagBits, TSub#(24, narrowTableIdxBits)),
    NumAlias#(wideTableTagBits, TSub#(24, wideTableIdxBits)),
    NumAlias#(narrowDistanceBits, 16),
    NumAlias#(narrowMaxDistanceAbs, TExp#(TSub#(narrowDistanceBits, 1))),
    Alias#(narrowTargetEntryT, NarrowTargetEntry#(narrowTableTagBits, narrowDistanceBits)),
    Alias#(wideTargetEntryT, WideTargetEntry#(wideTableTagBits)),
    Add#(a__, TLog#(narrowTableSize), 32),
    Add#(b__, TLog#(narrowTableSize), 58),
    Add#(c__, TLog#(wideTableSize), 32),
    Add#(d__, TLog#(wideTableSize), 58)
);

    //on any request, read all 4 tables. get prefetches. if it's a miss save both MRU entries.
    //on a miss, perform a regular table write to the MRU table. if it's a narrow write, write the old MRU narrow entry to the LRU narrow table.
    //one method, readReq, with parameter isMiss. sends read requests to all 4 tables.
    //also saves read address
    //one method setMRU.
    // sends a write request with the previous miss address to the current miss address.
    // if narrow table write, then also write the old MRU narrow entry to the LRU narrow table.
    //one method, getPrefetches, which also saves all results if isMiss true.
    RWBramCore#(Bit#(narrowTableIdxBits), Maybe#(narrowTargetEntryT)) narrowTableMRU <- mkRWBramCoreForwarded;
    RWBramCore#(Bit#(wideTableIdxBits), Maybe#(wideTargetEntryT)) wideTableMRU <- mkRWBramCoreForwarded;
    RWBramCore#(Bit#(narrowTableIdxBits), Maybe#(narrowTargetEntryT)) narrowTableLRU <- mkRWBramCoreForwarded;
    RWBramCore#(Bit#(wideTableIdxBits), Maybe#(wideTargetEntryT)) wideTableLRU <- mkRWBramCoreForwarded;
    Reg#(LineAddr) readReqLineAddr <- mkReg(0); 
    Reg#(HitOrMiss) readReqHitMiss <- mkReg(HIT);

    Reg#(LineAddr) lastMissAddr <- mkReg(0);
    Reg#(Maybe#(wideTargetEntryT)) lastMissWideMRUEntry <- mkReg(unpack(0));
    Reg#(Maybe#(narrowTargetEntryT)) lastMissNarrowMRUEntry <- mkReg(unpack(0));
    Reg#(Maybe#(wideTargetEntryT)) lastMissWideLRUEntry <- mkReg(unpack(0));
    Reg#(Maybe#(narrowTargetEntryT)) lastMissNarrowLRUEntry <- mkReg(unpack(0));

    function Bool narrowTagMatch(Bit#(32) addrHash, narrowTargetEntryT narrow);
        return narrow.tag == addrHash[23:valueOf(narrowTableIdxBits)];
    endfunction

    function Bool narrowTagMatchMaybe(Bit#(32) addrHash, Maybe#(narrowTargetEntryT) narrowMaybe);
        if (narrowMaybe matches tagged Valid .narrow &&& narrowTagMatch(addrHash, narrow))
            return True;
        else
            return False;
    endfunction

    function Bool wideTagMatch(Bit#(32) addrHash, wideTargetEntryT wide);
        return wide.tag == addrHash[23:valueOf(wideTableIdxBits)];
    endfunction

    function Bool wideTagMatchMaybe(Bit#(32) addrHash, Maybe#(wideTargetEntryT) wideMaybe);
        if (wideMaybe matches tagged Valid .wide &&& wideTagMatch(addrHash, wide))
            return True;
        else 
            return False;
    endfunction


    function ActionValue#(Maybe#(LineAddr))
        checkReadResp(LineAddr addr, Bit#(32) addrHash, Maybe#(narrowTargetEntryT) narrowWrapped, Maybe#(wideTargetEntryT) wideWrapped);
    actionvalue
        if (narrowWrapped matches tagged Valid .narrow
            &&& narrowTagMatch(addrHash, narrow)) begin
            //if (`VERBOSE) $display("%t found narrow table entry %h", $time, addr + signExtend(pack(narrow.distance)));
            return Valid(addr + signExtend(pack(narrow.distance)));
        end
        else if (wideWrapped matches tagged Valid .wide
            &&& wideTagMatch(addrHash, wide)) begin
            //if (`VERBOSE) $display("%t found wide table entry %h", $time, wide.target);
            return Valid(wide.target);
        end
        else
            return Invalid;
    endactionvalue
    endfunction

    function Action updateTables(
                                Bit#(32) lastMissAddrHash,
                                Bit#(idxBits) idx,
                                RWBramCore#(Bit#(idxBits), Maybe#(otherEntryT)) otherMRU,
                                RWBramCore#(Bit#(idxBits), Maybe#(otherEntryT)) otherLRU,
                                function Bool otherTagMatch(Bit#(32) addrHash, Maybe#(otherEntryT) entry),
                                function Bool myTagMatch(Bit#(32) addrHash, Maybe#(myEntryT) entry),
                                Maybe#(otherEntryT) otherMRUEntry,
                                Maybe#(otherEntryT) otherLRUEntry,
                                Maybe#(myEntryT) myMRUEntry
                                );
    action
    //Am inserting a new table entry into "my" table.
    //So need to re-order the entries in the "other" table.
    //To maintain the property that can't have both a narrow and wide entry in the same recency table.
        if (otherTagMatch(lastMissAddrHash, otherMRUEntry)) begin
            //If MRU other entry matches
            if (otherTagMatch(lastMissAddrHash, otherLRUEntry)) begin
                //If LRU other entry matches
                // Shift other down
                otherMRU.wrReq(idx, Invalid);
                otherLRU.wrReq(idx, otherMRUEntry);
            end
            else begin
                //If LRU other entry doesnt match
                // Switch other entries around
                otherMRU.wrReq(idx, otherLRUEntry);
                otherLRU.wrReq(idx, otherMRUEntry);
            end
        end
        else begin
            //If other MRU entry doesn't match
            if (otherTagMatch(lastMissAddrHash, otherLRUEntry) &&
                myTagMatch(lastMissAddrHash, myMRUEntry)) begin

                //will shift my MRU entry down, so
                // invalidate other LRU entry
                otherLRU.wrReq(idx, Invalid);
            end
        end
    endaction
    endfunction

    function Action writeMissEntry(LineAddr currAddr);
    action
        let distance = currAddr - lastMissAddr;
        Bit#(32) lastMissAddrHash = hash(lastMissAddr);
        if (`VERBOSE) $display("%t Recording miss from %x to %x", $time, lastMissAddr, currAddr);
        if (abs(distance) < fromInteger(valueOf(narrowMaxDistanceAbs))) begin
            //Store lastMissAddr -> currAddr in narrow MRU table

            Bit#(narrowTableIdxBits) idx = truncate(lastMissAddrHash);
            narrowTargetEntryT entry;
            entry.tag = lastMissAddrHash[23:valueOf(narrowTableIdxBits)];
            entry.distance = truncate(distance);

            if (Valid(entry) != lastMissNarrowMRUEntry) begin
                //if (`VERBOSE) $display("%t Recording miss -- modifying narrow table", $time);
                //Maintain the property that one address can only have 
                // at most 2 of 4 table entries for it.
                //Shift narrow table entries down, storing in MRU.
                //But only if the entry was not already the MRU entry.
                narrowTableMRU.wrReq(idx, Valid(entry));
                narrowTableLRU.wrReq(idx, lastMissNarrowMRUEntry);
                Bit#(wideTableIdxBits) wideIdx = truncate(lastMissAddrHash);
                updateTables(lastMissAddrHash, wideIdx, wideTableMRU, wideTableLRU, wideTagMatchMaybe, narrowTagMatchMaybe,
                    lastMissWideMRUEntry, lastMissWideLRUEntry, lastMissNarrowMRUEntry);
            end
        end
        else begin
            //Store lastMissAddr -> currAddr in wide MRU table
            wideTargetEntryT entry;
            Bit#(wideTableIdxBits) idx = truncate(lastMissAddrHash);
            entry.tag = lastMissAddrHash[23:valueOf(wideTableIdxBits)];
            entry.target = currAddr;

            if (Valid(entry) != lastMissWideMRUEntry) begin
                //if (`VERBOSE) $display("%t Recording miss -- modifying wide table", $time);
                wideTableMRU.wrReq(idx, Valid(entry));
                wideTableLRU.wrReq(idx, lastMissWideMRUEntry);
                Bit#(narrowTableIdxBits) narrowIdx = truncate(lastMissAddrHash);
                updateTables(lastMissAddrHash, narrowIdx, narrowTableMRU, narrowTableLRU, narrowTagMatchMaybe, wideTagMatchMaybe,
                    lastMissNarrowMRUEntry, lastMissNarrowLRUEntry, lastMissWideMRUEntry);
            end
        end
    endaction
    endfunction

    method Action sendReadWriteReq(LineAddr addr, HitOrMiss hitMiss);
        if (`VERBOSE) $display("%t send read write req for %x", $time, addr);
        Bit#(32) addrHash = hash(addr);
        Bit#(narrowTableIdxBits) narrowIdx = truncate(addrHash);
        narrowTableMRU.rdReq(narrowIdx);
        narrowTableLRU.rdReq(narrowIdx);
        Bit#(wideTableIdxBits) wideIdx = truncate(addrHash);
        wideTableMRU.rdReq(wideIdx);
        wideTableLRU.rdReq(wideIdx);
        readReqLineAddr <= addr;
        readReqHitMiss <= hitMiss;
    endmethod


    method ActionValue#(Tuple2#(Maybe#(LineAddr), Maybe#(LineAddr))) readResp();
        // Returns the read response and if a table had a hit, 
        // sends a write request to clear the entry in that table
        narrowTableMRU.deqRdResp;
        narrowTableLRU.deqRdResp;
        wideTableMRU.deqRdResp;
        wideTableLRU.deqRdResp;
        let addr = readReqLineAddr;
        Bit#(32) addrHash = hash(addr);
        if (readReqHitMiss == MISS) begin
            //Update the entries for the last miss to point to this one
            writeMissEntry(addr);
            //Save the raw table entries
            lastMissWideMRUEntry <= wideTableMRU.rdResp;
            lastMissNarrowMRUEntry <= narrowTableMRU.rdResp;
            lastMissWideLRUEntry <= wideTableLRU.rdResp;
            lastMissNarrowLRUEntry <= narrowTableLRU.rdResp;
            lastMissAddr <= addr; // save for future use
        end
        let entryMRU <- checkReadResp(addr, addrHash, narrowTableMRU.rdResp, wideTableMRU.rdResp);
        let entryLRU <- checkReadResp(addr, addrHash, narrowTableLRU.rdResp, wideTableLRU.rdResp);
        Tuple2#(Maybe#(LineAddr), Maybe#(LineAddr)) retval = tuple2(entryMRU, entryLRU);
        if (`VERBOSE) $display("%t Prefetcher read resp for %x returning ", $time, addr, fshow(retval));
        return retval;
    endmethod
endmodule

module mkSingleWindowTargetPrefetcher#(Parameter#(numLastRequests) _, Parameter#(cacheLinesInRange) __)(Prefetcher);
    Integer cacheLinesInRange = valueOf(cacheLinesInRange);
    Reg#(LineAddr) rangeEnd <- mkReg(0); //Points to one CLine after end of range
    Reg#(LineAddr) nextToAsk <- mkReg(0);

    Reg#(LineAddr) lastChildRequest <- mkReg(0);
    TargetTable#(8192, 2048) targetTable <- mkTargetTable;
    Fifo#(1, LineAddr) targetTableReadResp <- mkOverflowBypassFifo;

    Reg#(Vector#(numLastRequests, Bit#(16))) lastTargetRequests <- mkReg(replicate(0));

    rule sendReadReq;
    endrule

    rule getReadResp;
        let res <- targetTable.readResp();
        if (res matches tagged Valid .cline) begin
            targetTableReadResp.enq(cline);
        end
    endrule

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        let cl = getLineAddr(addr);
        if (`VERBOSE) $display("%t prefecher reportAccess", $time);
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
            nextToAsk <= cl + 1;
            rangeEnd <= cl + fromInteger(cacheLinesInRange) + 1;
        end

        if (hitMiss == MISS && cl != lastChildRequest + 1 && cl != lastChildRequest && cl != lastChildRequest - 1) begin
            //Try only recording table entries on a miss!
            if (`VERBOSE) $display("%t Prefetcher add target entry from addr %h to addr %h", $time, Addr'{lastChildRequest, '0}, addr);
            targetTable.writeReq(lastChildRequest, cl);
        end

        // Send target request if not in last numLastRequests hits.
        if (!elem(hash(cl), lastTargetRequests)) begin 
            targetTable.readReq(cl);
            if (`VERBOSE) $display("%t Prefetcher sending target read request for %h", $time, cl);
            lastTargetRequests <= shiftInAt0(lastTargetRequests, hash(cl));
        end
        lastChildRequest <= cl;
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr if (targetTableReadResp.notEmpty || nextToAsk != rangeEnd);
        Addr retAddr;
        if (targetTableReadResp.notEmpty) begin
            //If have valid table entry for some of the last requested clines, 
            // prefetch the stored target first
            retAddr = {targetTableReadResp.first, '0};
            targetTableReadResp.deq();
            if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting target entry %h", $time, retAddr);
        end
        else begin
            //If no table entry, prefetch further in window
            nextToAsk <= nextToAsk + 1;
            retAddr = {nextToAsk, '0}; 
            if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting next-line %h", $time, retAddr);
        end
        return retAddr; 
    endmethod
endmodule



module mkMultiWindowTargetPrefetcher#((Parameter#(numWindows)) _, Parameter#(numLastRequests) __, Parameter#(cacheLinesInRange) ___)(Prefetcher)
provisos(
    Alias#(windowIdxT, Bit#(TLog#(numWindows)))
);
    Integer cacheLinesInRange = valueOf(cacheLinesInRange);
    Vector#(numWindows, Reg#(StreamEntry)) streams 
        <- replicateM(mkReg(StreamEntry {rangeEnd: '0, nextToAsk: '0}));
    Vector#(numWindows, Reg#(windowIdxT)) shiftReg <- genWithM(compose(mkReg, fromInteger));
    Reg#(LineAddr) lastChildRequest <- mkReg(0);

    TargetTable#(8192, 2048) targetTable <- mkTargetTable;
    FIFOF#(LineAddr) targetTableReadResp <- mkBypassFIFOF;
    Reg#(Vector#(numLastRequests, Bit#(32))) lastTargetRequests <- mkReg(replicate(0));

    rule sendReadReq;
        if (!elem(hash(lastChildRequest), lastTargetRequests)) begin 
            targetTable.readReq(lastChildRequest);
            if (`VERBOSE) $display("%t Prefetcher sending target read request for %h", $time, Addr'{lastChildRequest, 'h0});
            lastTargetRequests <= shiftInAt0(lastTargetRequests, hash(lastChildRequest));
        end
    endrule

    rule getReadResp;
        let res <- targetTable.readResp();
        if (res matches tagged Valid .cline) begin
            targetTableReadResp.enq(cline);
        end
    endrule

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

    function ActionValue#(Maybe#(windowIdxT)) getMatchingWindow(LineAddr cl) = 
    actionvalue
        //Finds the first window that contains cache line
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
        let cl = getLineAddr(addr);
        // Update window prefetcher
        let idxMaybe <- getMatchingWindow(cl);
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

        // Update target prefetcher
        if (hitMiss == MISS && cl != lastChildRequest + 1 && cl != lastChildRequest && cl != lastChildRequest - 1) begin
            if (`VERBOSE) $display("%t Prefetcher add target entry from addr %h to addr %h", $time, Addr'{lastChildRequest, '0}, addr);
            targetTable.writeReq(lastChildRequest, cl);
        end
        lastChildRequest <= cl;
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr 
        if (targetTableReadResp.notEmpty || streams[shiftReg[0]].nextToAsk != streams[shiftReg[0]].rangeEnd);

        Addr retAddr;
        let lastAsked = streams[shiftReg[0]].nextToAsk-1;
        if (targetTableReadResp.notEmpty) begin
            //If have valid table entry for some of the last requested clines, 
            // prefetch the stored target first
            retAddr = {targetTableReadResp.first, '0};
            targetTableReadResp.deq();
            if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting target entry %h", $time, retAddr);
        end
        else begin
            streams[shiftReg[0]].nextToAsk <= streams[shiftReg[0]].nextToAsk + 1;
            retAddr = Addr'{streams[shiftReg[0]].nextToAsk, '0}; //extend cache line address to regular address
            if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting %h from window idx %h", $time, retAddr, shiftReg[0]);
        end
        return retAddr; 
    endmethod

endmodule

module mkMarkovPrefetcher#(Parameter#(maxChainLength) _, Parameter#(narrowEntries) __, Parameter#(wideEntries) ___)(Prefetcher) provisos
(
    Alias#(chainLengthT, Bit#(TLog#(TAdd#(maxChainLength,1)))),
    Add#(a__, TLog#(narrowEntries), 32),
    Add#(b__, TLog#(narrowEntries), 58),
    Add#(c__, TLog#(wideEntries), 32),
    Add#(d__, TLog#(wideEntries), 58)
);
    Reg#(LineAddr) lastLastChildRequest <- mkReg(0);
    Reg#(LineAddr) lastChildRequest <- mkReg(0);
    TargetTable#(narrowEntries, wideEntries) targetTable <- mkTargetTable;
    FIFOF#(LineAddr) targetTableReadResp <- mkBypassFIFOF;

    // Stores how many prefetches we can still do in the current chain
    Reg#(chainLengthT) chainNumberToPrefetch <- mkReg(0); 
    Reg#(LineAddr) chainNextToLookup <- mkReg(?);

    rule sendReadReq (chainNumberToPrefetch != 0);
        if (`VERBOSE) if (`VERBOSE) $display ("%t Prefetcher send read req for  %h", $time, Addr'{chainNextToLookup, '0});
        targetTable.readReq(chainNextToLookup);
    endrule

    (* descending_urgency = "getReadResp, sendReadReq" *)
    (* execution_order = "getReadResp, sendReadReq" *)
    rule getReadResp;
        let res <- targetTable.readResp();
        if (res matches tagged Valid .cline) begin
            targetTableReadResp.enq(cline);
            chainNextToLookup <= cline;
            chainNumberToPrefetch <= chainNumberToPrefetch - 1;
            if (`VERBOSE) if (`VERBOSE) $display("%t Prefetcher found read resp data! %h", $time, Addr'{cline, '0});
        end
        else begin
            if (`VERBOSE) if (`VERBOSE) $display("%t Prefetcher found read resp invalid!", $time);
            chainNumberToPrefetch <= 0;
        end
    endrule

    method ActionValue#(Addr) getNextPrefetchAddr;
        targetTableReadResp.deq();
        let cline = targetTableReadResp.first;
        Addr retAddr = {cline, '0};
        if (`VERBOSE) if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting chain entry %h", $time, retAddr);
        return retAddr; 
    endmethod

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        let cl = getLineAddr(addr);
        if (hitMiss == MISS && cl != lastChildRequest) begin
            //Test only tracking misses, to avoid double noise of too many requests, many to the same location
            if (`VERBOSE) if (`VERBOSE) $display("%t Prefetcher report %s add target entry from addr %h to addr %h", 
                $time, hitMiss == HIT ? "HIT" : "MISS", Addr'{lastChildRequest, '0}, Addr'{cl, '0});
            targetTable.writeReq(lastChildRequest, cl);
            lastChildRequest <= cl;
            lastLastChildRequest <= lastChildRequest;
        end

        if (hitMiss == MISS) begin 
            if (`VERBOSE) if (`VERBOSE) $display("%t Prefetcher start new chain with %h", $time, addr);
            chainNextToLookup <= cl;
            chainNumberToPrefetch <= fromInteger(valueOf(maxChainLength));
        end
    endmethod

endmodule

module mkMarkovOnHitPrefetcher#(Parameter#(maxChainLength) _, Parameter#(numLastRequestsTracked) __)(Prefetcher) provisos
(
    Alias#(chainLengthT, Bit#(TLog#(TAdd#(maxChainLength,1))))
);
    Reg#(LineAddr) lastLastChildRequest <- mkReg(0);
    Reg#(LineAddr) lastChildRequest <- mkReg(0);
    Reg#(Vector#(numLastRequestsTracked, Bit#(32))) lastAddrRequests <- mkReg(replicate(0));
    TargetTable#(2048, 128) targetTable <- mkTargetTable;
    FIFOF#(LineAddr) targetTableReadResp <- mkBypassFIFOF;

    // Stores how many prefetches we can still do in the current chain
    Reg#(chainLengthT) chainNumberToPrefetch <- mkReg(0); 
    Reg#(LineAddr) chainNextToLookup <- mkReg(?);

    rule sendReadReq (chainNumberToPrefetch != 0);
        if (`VERBOSE) $display ("%t Prefetcher send read req for  %h", $time, Addr'{chainNextToLookup, '0});
        targetTable.readReq(chainNextToLookup);
    endrule

    (* descending_urgency = "getReadResp, sendReadReq" *)
    (* execution_order = "getReadResp, sendReadReq" *)
    rule getReadResp;
        let res <- targetTable.readResp();
        if (res matches tagged Valid .cline) begin
            targetTableReadResp.enq(cline);
            chainNextToLookup <= cline;
            chainNumberToPrefetch <= chainNumberToPrefetch - 1;
            if (`VERBOSE) $display("%t Prefetcher found read resp data! %h", $time, Addr'{cline, '0});
        end
        else begin
            if (`VERBOSE) $display("%t Prefetcher found read resp invalid!", $time);
            chainNumberToPrefetch <= 0;
        end
    endrule

    method ActionValue#(Addr) getNextPrefetchAddr;
        targetTableReadResp.deq();
        let cline = targetTableReadResp.first;
        Addr retAddr = {cline, '0};
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting chain entry %h", $time, retAddr);
        return retAddr; 
    endmethod

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        let cl = getLineAddr(addr);
        if (hitMiss == MISS && cl != lastChildRequest) begin
            //Test only tracking misses, to avoid double noise of too many requests, many to the same location
            if (`VERBOSE) $display("%t Prefetcher report %s add target entry from addr %h to addr %h", 
                $time, hitMiss == HIT ? "HIT" : "MISS", Addr'{lastChildRequest, '0}, Addr'{cl, '0});
            targetTable.writeReq(lastChildRequest, cl);
            lastChildRequest <= cl;
            lastLastChildRequest <= lastChildRequest;
        end

        if (!elem(hash(cl), lastAddrRequests)) begin 
            //Don't start markov chain if we started a markov chain with that address recently
            if (`VERBOSE) $display("%t Prefetcher start new chain with %h", $time, addr);
            lastAddrRequests <= shiftInAt0(lastAddrRequests, hash(cl));
            chainNextToLookup <= cl;
            chainNumberToPrefetch <= fromInteger(valueOf(maxChainLength));
        end
    endmethod

endmodule

module mkMarkovOnHit2Prefetcher#(Parameter#(maxChainLength) _, Parameter#(numLastRequestsTracked) __)(Prefetcher) provisos
(
    Alias#(chainLengthT, Bit#(TLog#(TAdd#(maxChainLength,1))))
);
    Reg#(LineAddr) lastChildRequest <- mkReg(0);
    Reg#(Vector#(numLastRequestsTracked, Bit#(32))) lastAddrRequests <- mkReg(replicate(0));
    TargetTableDouble#(65536, 4096) targetTable <- mkTargetTableDouble;
    Fifo#(8, LineAddr) highPriorityPrefetches <- mkOverflowBypassFifo;
    Fifo#(8, LineAddr) lowPriorityPrefetches <- mkOverflowBypassFifo;

    //on reportAccess, read the current address in both tables, and save it
    // Next cycle, add any found next lines to prefetch queues. Have 2 prefetch queues, High and low priority.
    // If this was a miss, save as lastMissEntry
    // And issue a write of table[lastMissEntry] = thisMiss.
    // but checking for LRU and everything.

    rule addPrefetchesToQueues;
        if (`VERBOSE) $display("%t Prefetcher Add prefetch to queue!", $time);
        match { .highPrio, .lowPrio } <- targetTable.readResp();
        if (highPrio matches tagged Valid .cl) begin
            highPriorityPrefetches.enq(cl);
        end
        if (lowPrio matches tagged Valid .cl) begin
            lowPriorityPrefetches.enq(cl);
        end
    endrule

    method ActionValue#(Addr) getNextPrefetchAddr 
                 if (highPriorityPrefetches.notEmpty || lowPriorityPrefetches.notEmpty);
        Addr retAddr = unpack(0);
        if (highPriorityPrefetches.notEmpty) begin
            retAddr = {highPriorityPrefetches.first, '0};
            highPriorityPrefetches.deq;
        end
        else if (lowPriorityPrefetches.notEmpty) begin
            retAddr = {lowPriorityPrefetches.first, '0};
            lowPriorityPrefetches.deq;
        end
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting chain entry %h", $time, retAddr);
        return retAddr; 
    endmethod

    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        let cl = getLineAddr(addr);
        if (hitMiss == MISS)
            if (`VERBOSE) $display("%t Prefetcher report MISS %h", $time, addr);

        if (hitMiss == MISS || !elem(hash(cl), lastAddrRequests)) begin 
            //Don't start a markov chain if we started a markov chain with that address recently
            if (`VERBOSE) $display("%t Prefetcher start new chain with %h", $time, addr);
            targetTable.sendReadWriteReq(cl, hitMiss);
            lastAddrRequests <= shiftInAt0(lastAddrRequests, hash(cl));
        end
    endmethod

endmodule
module mkBlockPrefetcher#(Parameter#(numLinesEachWay) _)(Prefetcher) provisos (
    Alias#(lineCountT, Bit#(TLog#(TAdd#(numLinesEachWay, 1)))),
    Add#(a__, TLog#(TAdd#(numLinesEachWay, 1)), 58)
);
    Reg#(Bool) nextIsForward <- mkReg(?);
    Reg#(LineAddr) prefetchAround <- mkReg(?);
    Reg#(lineCountT) linesEachWayPrefetched <- mkReg(fromInteger(valueOf(numLinesEachWay)));
    method Action reportAccess(Addr addr, HitOrMiss hitMiss);
        if (hitMiss == MISS) begin
            if (`VERBOSE) $display("%t Prefetcher report MISS %h", $time, addr);
            nextIsForward <= True;
            prefetchAround <= getLineAddr(addr);
            linesEachWayPrefetched <= 0;
        end
        else 
            if (`VERBOSE) $display("%t Prefetcher report HIT %h", $time, addr);
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if (linesEachWayPrefetched != fromInteger(valueOf(numLinesEachWay)));
        nextIsForward <= !nextIsForward;
        if (nextIsForward) begin
            Addr retAddr = {prefetchAround + (extend(linesEachWayPrefetched)+1), 0};
            if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting forward %h", $time, retAddr);
            return retAddr;
        end
        else begin
            Addr retAddr = {prefetchAround - (extend(linesEachWayPrefetched)+1), 0};
            if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr requesting backward %h", $time, retAddr);
            linesEachWayPrefetched <= linesEachWayPrefetched + 1;
            return retAddr;
        end
    endmethod

endmodule

module mkPCPrefetcherAdapter#(module#(Prefetcher) mkPrefetcher)(PCPrefetcher);
    let p <- mkPrefetcher;
    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
        p.reportAccess(addr, hitMiss);
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr;
        let x <- p.getNextPrefetchAddr;
        return x;
    endmethod
endmodule

module mkDoNothingPCPrefetcher(PCPrefetcher);
    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if (False);
        return 64'h0000000080000080;
    endmethod
endmodule

module mkPrintPCPrefetcher(PCPrefetcher);
    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
        if (hitMiss == HIT)
            if (`VERBOSE) $display("%t PCPrefetcher report HIT %h", $time, addr);
        else
            if (`VERBOSE) $display("%t PCPrefetcher report MISS %h", $time, addr);
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr if (False);
        return 64'h0000000080000080;
    endmethod
endmodule

typedef enum {
  EMPTY = 2'b00, INIT = 2'b01, TRANSIENT = 2'b10, STEADY = 2'b11
} StrideState deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(12) lastAddr; 
    Bit#(13) stride;
    StrideState state;
    Bit#(4) cLinesPrefetched; //Stores how many cache lines have been prefetched for this instruction
} StrideEntry deriving (Bits, Eq, FShow);

module mkStridePCPrefetcher#(Parameter#(strideTableSize) _, Parameter#(cLinesAheadToPrefetch) __)(PCPrefetcher)
provisos(
    Alias#(strideTableIndexT, Bit#(TLog#(strideTableSize))),
    Add#(a__, TLog#(strideTableSize), 16)
    );
    RWBramCore#(strideTableIndexT, StrideEntry) strideTable <- mkRWBramCoreForwarded;
    FIFOF#(Tuple3#(Addr, Bit#(16), HitOrMiss)) memAccesses <- mkSizedBypassFIFOF(8);
    Reg#(Tuple3#(Addr, Bit#(16), HitOrMiss)) rdRespEntry <- mkReg(?);

    Fifo#(8, Addr) addrToPrefetch <- mkOverflowPipelineFifo;
    FIFO#(Tuple3#(StrideEntry, Addr, Bit#(16))) strideEntryForPrefetch <- mkBypassFIFO();
    Reg#(Maybe#(Bit#(4))) cLinesPrefetchedLatest <- mkReg(Invalid);
    PulseWire holdReadReq <- mkPulseWire;

    rule sendReadReq if (!holdReadReq);
        match {.addr, .pcHash, .hitMiss} = memAccesses.first;
        if (`VERBOSE) $display("%t Sending read req for %h!", $time, pcHash);
        strideTable.rdReq(truncate(pcHash));
        rdRespEntry <= memAccesses.first;
        memAccesses.deq;
    endrule


    rule updateStrideEntry;
        //Find slot in vector
        //if miss and slot empty
        //if slot init, put address, stride and move to transit
        //if slot transit or steady, verify stride, and move to steady
        //    also put last_prefetched
        //if stride wrong, move to transit
        match {.addr, .pcHash, .hitMiss} = rdRespEntry;
        strideTableIndexT index = truncate(pcHash);
        StrideEntry se = strideTable.rdResp;
        strideTable.deqRdResp;
        StrideEntry seNext = se;
        Bit#(13) observedStride = {1'b0, addr[11:0]} - {1'b0, se.lastAddr};
        $writeh("%t Stride Prefetcher updateStrideEntry ", $time,
            fshow(hitMiss), " ", addr,
            ". Entry ", index, " state is ", fshow(se.state));
        if (se.state == EMPTY) begin
            if (hitMiss == MISS) begin 
                seNext.lastAddr = truncate(addr);
                seNext.state = INIT;
                if (`VERBOSE) $display(", allocate entry");
            end
            else begin
                if (`VERBOSE) $display(", ignore");
            end
        end 
        else if (se.state == INIT && observedStride != 0) begin
            seNext.stride = observedStride;
            seNext.state = TRANSIENT;
            seNext.lastAddr = truncate(addr);
            if (`VERBOSE) $display(", set stride to %h", seNext.stride);
        end
        else if ((se.state == TRANSIENT || se.state == STEADY) && observedStride != 0) begin
            if (observedStride == se.stride) begin
                if (se.state == TRANSIENT) begin
                    //Here we transition from TRANSIENT to STEADY, so init this field
                    seNext.cLinesPrefetched = 0;
                end
                else begin
                    //state == STEADY
                    if (se.lastAddr[11:6] != addr[11:6]) begin
                        //This means we have crossed a cache line since last access
                        seNext.cLinesPrefetched = 
                            (se.cLinesPrefetched == 0) ? 0 : se.cLinesPrefetched - 1;
                    end
                end
                seNext.state = STEADY;
                seNext.lastAddr = truncate(addr);
                if (`VERBOSE) $display(", stride %h is confirmed!", seNext.stride);
            end
            else begin
                seNext.state = TRANSIENT;
                seNext.stride = observedStride;
                seNext.lastAddr = truncate(addr);
                if (`VERBOSE) $display(", old stride is broken! New stride: %h", seNext.stride);
            end
        end
        else
            if (`VERBOSE) $display("");
        
        strideEntryForPrefetch.enq(tuple3(seNext, addr, pcHash));
    endrule

    rule createPrefetchRequests;
        match {.se, .addr, .pcHash} = strideEntryForPrefetch.first;
        //If this rule is looping, then we'll have a valid cLinesPrefetchedLatest
        Bit#(4) cLinesPrefetched = fromMaybe(se.cLinesPrefetched, cLinesPrefetchedLatest);

        if (se.state == STEADY && 
            cLinesPrefetched != 
            fromInteger(valueof(cLinesAheadToPrefetch))) begin
            //can prefetch
            
            Bit#(13) strideToUse;
            Bit#(13) cLineSize = fromInteger(valueof(DataSz));
            if (se.stride[12] == 1 && se.stride > -cLineSize) begin
                //stride is negative and jumps less than one cline
                strideToUse = -cLineSize;
            end
            else if (se.stride[12] == 0 && se.stride < cLineSize) begin
                //stride is positive and jumps less than one cline
                strideToUse = cLineSize;
            end 
            else begin
                strideToUse = se.stride;
            end

            let reqAddr = addr + 
                (signExtend(strideToUse) * zeroExtend(cLinesPrefetched + 1));

            addrToPrefetch.enq(reqAddr);
            // We will still be processing this StrideEntry next cycle, 
            // so hold off any potential read requests until we do a writeback
            holdReadReq.send();
            cLinesPrefetchedLatest <= Valid(cLinesPrefetched + 1);
            if (`VERBOSE) $display("%t Stride Prefetcher getNextPrefetchAddr requesting %h for entry %h", $time, reqAddr, pcHash[7:0]);
        end
        else begin
            //cant prefetch
            if (`VERBOSE) $display("%t Stride Prefetcher no possible prefetch for entry %h", $time, strideTableIndexT'(truncate(pcHash)));
            strideEntryForPrefetch.deq;
            se.cLinesPrefetched = cLinesPrefetched;
            cLinesPrefetchedLatest <= Invalid;
            strideTable.wrReq(truncate(pcHash), se);
        end
    endrule

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
        memAccesses.enq(tuple3 (addr, pcHash, hitMiss));
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
        addrToPrefetch.deq;
        return addrToPrefetch.first;
    endmethod

endmodule

typedef enum {
  INIT = 2'd0, TRANSIENT = 2'd1, STEADY = 2'd2, NO_PRED = 2'd3
} StrideState2 deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(12) lastAddr; 
    Int#(12) stride;
    Bit#(2) cLinesPrefetched; //Stores how many cache lines have been prefetched for this instruction
    StrideState2 state;
} StrideEntry2 deriving (Bits, Eq, FShow);

module mkStride2PCPrefetcher(PCPrefetcher)
provisos(
    NumAlias#(strideTableSize, 512),
    NumAlias#(cLinesAheadToPrefetch, 2), 
    Alias#(strideTableIndexT, Bit#(TLog#(strideTableSize)))
    );
    RWBramCore#(strideTableIndexT, StrideEntry2) strideTable <- mkRWBramCoreForwarded;
    FIFOF#(Tuple3#(Addr, Bit#(16), HitOrMiss)) memAccesses <- mkSizedBypassFIFOF(8);
    Reg#(Tuple3#(Addr, Bit#(16), HitOrMiss)) rdRespEntry <- mkReg(?);

    Fifo#(8, Addr) addrToPrefetch <- mkOverflowPipelineFifo;
    FIFO#(Tuple3#(StrideEntry2, Addr, Bit#(16))) strideEntryForPrefetch <- mkBypassFIFO();
    Reg#(Maybe#(Bit#(2))) cLinesPrefetchedLatest <- mkReg(?);
    PulseWire holdReadReq <- mkPulseWire;

    rule sendReadReq if (!holdReadReq);
        match {.addr, .pcHash, .hitMiss} = memAccesses.first;
        if (`VERBOSE) $display("%t Sending read req for %h!", $time, pcHash);
        strideTable.rdReq(truncate(pcHash));
        rdRespEntry <= memAccesses.first;
        memAccesses.deq;
    endrule


    rule updateStrideEntry;
        //Find slot in vector
        //if miss and slot empty
        //if slot init, put address, stride and move to transit
        //if slot transit or steady, verify stride, and move to steady
        //    also put last_prefetched
        //if stride wrong, move to transit
        match {.addr, .pcHash, .hitMiss} = rdRespEntry;
        strideTableIndexT index = truncate(pcHash);
        StrideEntry2 se = strideTable.rdResp;
        strideTable.deqRdResp;
        StrideEntry2 seNext = se;
        Int#(12) observedStride = unpack(addr[11:0] - se.lastAddr);
        $writeh("%t Stride Prefetcher updateStrideEntry ", $time,
            fshow(hitMiss), " ", addr,
            ". Entry ", index, " state is ", fshow(se.state));
        if (se.state == INIT && observedStride != 0) begin
            if (se.stride == observedStride) begin
                //fast track to steady
                seNext.state = STEADY;
                if (`VERBOSE) $display(", stride matches so fast track back to STEADY");
            end
            else begin
                seNext.stride = observedStride;
                seNext.state = TRANSIENT;
                if (`VERBOSE) $display(", stride doesn't match, so set to %h", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else if (se.state == TRANSIENT && observedStride != 0) begin
            if (observedStride == se.stride) begin
                //stride confimed, move to steady
                seNext.cLinesPrefetched = 0;
                seNext.state = STEADY;
                if (`VERBOSE) $display(", stride %h is confirmed!", seNext.stride);
            end
            else begin
                //We're seeing random accesses, go to no pred
                seNext.state = NO_PRED;
                seNext.stride = observedStride;
                if (`VERBOSE) $display(", we have a random stride (%h), go to NO_PRED", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else if (se.state == STEADY && observedStride != 0) begin
            if (observedStride == se.stride) begin
                if (se.lastAddr[11:6] != addr[11:6]) begin
                    //This means we have crossed a cache line since last access
                    seNext.cLinesPrefetched = 
                        (se.cLinesPrefetched == 0) ? 0 : se.cLinesPrefetched - 1;
                end
                if (`VERBOSE) $display(", stride %h stays confirmed!", seNext.stride);
            end
            else begin
                //We jump to some other random location, so reset number of lines prefetched
                seNext.cLinesPrefetched = 0;
                seNext.state = INIT;
                if (`VERBOSE) $display(", random jump (%x)! Move to INIT, don't reset stride", observedStride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else if (se.state == NO_PRED && observedStride != 0) begin
            if (observedStride == se.stride) begin
                seNext.state = TRANSIENT;
                if (`VERBOSE) $display(", have repeated stride: %h, move to TRANSIENT", seNext.stride);
            end
            else begin
                seNext.stride = observedStride;
                if (`VERBOSE) $display(", have random stride: %h", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else
            if (`VERBOSE) $display("");
        
        strideEntryForPrefetch.enq(tuple3(seNext, addr, pcHash));
    endrule

    rule createPrefetchRequests;
        match {.se, .addr, .pcHash} = strideEntryForPrefetch.first;
        //If this rule is looping, then we'll have a valid cLinesPrefetchedLatest
        Bit#(2) cLinesPrefetched = fromMaybe(se.cLinesPrefetched, cLinesPrefetchedLatest);

        Int#(16) cLineSize = fromInteger(valueof(DataSz));
        Int#(16) strideToUse = signExtend(se.stride);
        if (abs(strideToUse) < cLineSize) begin
            strideToUse = (strideToUse < 0) ? -cLineSize : cLineSize; 
        end
        Bit#(16) jumpDist = pack(strideToUse) * zeroExtend(cLinesPrefetched+1);
        let reqAddr = addr + signExtend(jumpDist);

        if (se.state == STEADY && 
            cLinesPrefetched != 
            fromInteger(valueof(cLinesAheadToPrefetch)) &&
            reqAddr[63:12] == addr[63:12] //Check if same page
        ) begin
            //can prefetch

            addrToPrefetch.enq(reqAddr);
            // We will still be processing this StrideEntry next cycle, 
            // so hold off any potential read requests until we do a writeback
            holdReadReq.send();
            cLinesPrefetchedLatest <= Valid(cLinesPrefetched + 1);
            if (`VERBOSE) $display("%t Stride Prefetcher getNextPrefetchAddr requesting %h for entry %h", $time, reqAddr, pcHash[7:0]);
        end
        else begin
            //cant prefetch
            if (`VERBOSE) $display("%t Stride Prefetcher no possible prefetch for entry %h", $time, strideTableIndexT'(truncate(pcHash)));
            strideEntryForPrefetch.deq;
            se.cLinesPrefetched = cLinesPrefetched;
            cLinesPrefetchedLatest <= Invalid;
            strideTable.wrReq(truncate(pcHash), se);
        end
    endrule

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
        memAccesses.enq(tuple3 (addr, pcHash, hitMiss));
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
        addrToPrefetch.deq;
        return addrToPrefetch.first;
    endmethod

endmodule

typedef struct {
    Addr lastAddr; 
    Int#(13) stride;
    Bit#(2) confidence;
} SimpleStrideEntry deriving (Bits, Eq, FShow);

//Reasonable parameter values:
//strideTableSize = 512
//cLinesAheadToPrefetch = 2
//minConfidenceToPrefetch = 2
module mkSimpleStridePCPrefetcher#(Parameter#(strideTableSize) _, Parameter#(cLinesAheadToPrefetch) __, Parameter#(minConfidenceToPrefetch) ___)(PCPrefetcher)
provisos(
    Alias#(strideTableIndexT, Bit#(TLog#(strideTableSize))),
    Add#(a__, TLog#(strideTableSize), 16)
    );
    Vector#(strideTableSize, Reg#(SimpleStrideEntry)) strideTable <- replicateM(mkReg(unpack(0)));

    Reg#(Addr) addrToPrefetch <- mkReg(0);
    Reg#(Int#(13)) strideToPrefetch <- mkReg(0);
    Ehr#(2, Bit#(3)) prefetchesIssued <- mkEhr(fromInteger(valueOf(cLinesAheadToPrefetch)));

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
        if (`VERBOSE) $display("%t reportAccess %x %x", $time, addr, pcHash);
        strideTableIndexT idx = truncate(pcHash);
        SimpleStrideEntry entry = strideTable[idx];
        Int#(13) calc_stride = unpack(truncate(addr - entry.lastAddr));
        entry.lastAddr = addr;
        if (calc_stride == entry.stride) begin
            if (entry.confidence != 2'd3) begin
                entry.confidence = entry.confidence + 1;
            end
        end
        else begin
            if (entry.confidence > 0) begin
                entry.confidence = entry.confidence - 1;
            end
            if (entry.confidence < fromInteger(valueOf(minConfidenceToPrefetch))) begin
                entry.stride = calc_stride;
                entry.confidence = 0;
            end
        end
        
        if (entry.confidence >= fromInteger(valueOf(minConfidenceToPrefetch))) begin
            prefetchesIssued[1] <= 0;
            addrToPrefetch <= addr;
            strideToPrefetch <= entry.stride;
        end
        strideTable[idx] <= entry;
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr 
            if (prefetchesIssued[0] < fromInteger(valueOf(cLinesAheadToPrefetch)));
        
        Int#(13) strideToUse = strideToPrefetch;
        Int#(13) cLineSize = fromInteger(valueof(DataSz));
        if (abs(strideToPrefetch) < cLineSize) begin
            strideToUse = (strideToPrefetch < 0) ? -cLineSize : cLineSize;
        end

        prefetchesIssued[0] <= prefetchesIssued[0] + 1; 
        let reqAddr = addrToPrefetch + 
            (pack(signExtend(strideToUse)) * zeroExtend(prefetchesIssued[0] + 1));

        check(reqAddr[63:12] == addrToPrefetch[63:12]);
        if (`VERBOSE) $display("%t getNextPrefetchAddr returning %x", $time, reqAddr);
        return reqAddr;
    endmethod

endmodule

typedef enum {
    EMPTY = 3'd0, INIT = 3'd1, TRANSIENT = 3'd2, STEADY1 = 3'd3, 
    STEADY2 = 3'd4, STEADY3 = 3'd5, STEADY4 = 4'd6, STEADYLAST = 3'd7
} StrideStateAdaptive deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(12) lastAddr; 
    Bit#(13) stride;
    StrideStateAdaptive state;
    Bit#(4) cLinesPrefetched; //Stores how many cache lines have been prefetched for this instruction
} StrideEntryAdaptive deriving (Bits, Eq, FShow);

module mkStrideAdaptivePCPrefetcher#(
    Parameter#(strideTableSize) _, 
    Parameter#(cLinesPrefetchMin) __,
    Parameter#(cLinesSmallStridePrefetchMax) ___,
    Parameter#(cLinesBigStridePrefetchMax) ____
    )(PCPrefetcher)
provisos(
    Alias#(strideTableIndexT, Bit#(TLog#(strideTableSize))),
    Add#(a__, TLog#(strideTableSize), 16)
    );
    RWBramCore#(strideTableIndexT, StrideEntryAdaptive) strideTable <- mkRWBramCoreForwarded;
    FIFOF#(Tuple3#(Addr, Bit#(16), HitOrMiss)) memAccesses <- mkSizedBypassFIFOF(8);
    Reg#(Tuple3#(Addr, Bit#(16), HitOrMiss)) rdRespEntry <- mkReg(?);

    Fifo#(8, Addr) addrToPrefetch <- mkOverflowPipelineFifo;
    FIFO#(Tuple3#(StrideEntryAdaptive, Addr, Bit#(16))) strideEntryForPrefetch <- mkBypassFIFO();
    Reg#(Maybe#(Bit#(4))) cLinesPrefetchedLatest <- mkReg(?);
    PulseWire holdReadReq <- mkPulseWire;

    function StrideStateAdaptive incrementSteady(StrideStateAdaptive state);
        case (state)
            STEADY1: return STEADY2;
            STEADY2: return STEADY3; 
            STEADY3: return STEADY4; 
            STEADY4: return STEADYLAST; 
            STEADYLAST: return STEADYLAST; 
            default: return STEADY1;
        endcase
    endfunction

    function Bool stateAtLeastSteady(StrideStateAdaptive state);
        return (state == STEADY1 ||
                state == STEADY2 ||
                state == STEADY3 ||
                state == STEADY4 ||
                state == STEADYLAST);
    endfunction

    function Bit#(4) cLinesAheadToPrefetch(StrideStateAdaptive state, Bit#(13) stride);
        let absStride = abs(stride);
        if (absStride <= 8) begin
            if (state == STEADY4 || state == STEADYLAST) begin
                return fromInteger(valueof(cLinesSmallStridePrefetchMax));
            end
            else begin
                return fromInteger(valueof(cLinesPrefetchMin));
            end
        end
        else begin
            //big strides
            if (state == STEADYLAST) begin
                return fromInteger(valueof(cLinesBigStridePrefetchMax));
            end
            else if (state == STEADY3 || state == STEADY4) begin
                return fromInteger(valueof(cLinesBigStridePrefetchMax))-1;
            end
            else begin
                return fromInteger(valueof(cLinesPrefetchMin));
            end
        end
    endfunction

    rule sendReadReq if (!holdReadReq);
        match {.addr, .pcHash, .hitMiss} = memAccesses.first;
        if (`VERBOSE) $display("%t Sending read req for %h!", $time, pcHash);
        strideTable.rdReq(truncate(pcHash));
        rdRespEntry <= memAccesses.first;
        memAccesses.deq;
    endrule


    rule updateStrideEntry;
        //Find slot in vector
        //if miss and slot empty
        //if slot init, put address, stride and move to transit
        //if slot transit or steady, verify stride, and move to steady
        //    also put last_prefetched
        //if stride wrong, move to transit
        match {.addr, .pcHash, .hitMiss} = rdRespEntry;
        strideTableIndexT index = truncate(pcHash);
        StrideEntryAdaptive se = strideTable.rdResp;
        strideTable.deqRdResp;
        StrideEntryAdaptive seNext = se;
        Bit#(13) observedStride = {1'b0, addr[11:0]} - {1'b0, se.lastAddr};
        $writeh("%t Stride Prefetcher updateStrideEntry ", $time,
            fshow(hitMiss), " ", addr,
            ". Entry ", index, " state is ", fshow(se.state));
        if (se.state == EMPTY) begin
            if (hitMiss == MISS) begin 
                seNext.lastAddr = truncate(addr);
                seNext.state = INIT;
                if (`VERBOSE) $display(", allocate entry");
            end
            else begin
                if (`VERBOSE) $display(", ignore");
            end
        end 
        else if (se.state == INIT && observedStride != 0) begin
            seNext.stride = observedStride;
            seNext.state = TRANSIENT;
            seNext.lastAddr = truncate(addr);
            if (`VERBOSE) $display(", set stride to %h", seNext.stride);
        end
        else if (se.state == TRANSIENT && observedStride != 0) begin
            if (observedStride == se.stride) begin
                //Here we transition from TRANSIENT to STEADY, so init this field
                seNext.cLinesPrefetched = 0;
                seNext.state = STEADY1;
                if (`VERBOSE) $display(", stride %h is confirmed!", seNext.stride);
            end
            else begin
                seNext.state = TRANSIENT;
                seNext.stride = observedStride;
                if (`VERBOSE) $display(", old stride is broken! New stride: %h", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else if (stateAtLeastSteady(se.state) && observedStride != 0) begin
            if (observedStride == se.stride) begin
                if (se.lastAddr[11:6] != addr[11:6]) begin
                    //This means we have crossed a cache line since last access
                    seNext.cLinesPrefetched = 
                        (se.cLinesPrefetched == 0) ? 0 : se.cLinesPrefetched - 1;
                end
                seNext.state = incrementSteady(se.state);
                if (`VERBOSE) $display(", stride %h is sustained, advance STEADY number!", se.stride);
            end
            else if (se.state == STEADY4 || se.state == STEADYLAST) begin
                //Leniency towards some stride changes
                seNext.state = STEADY1;
                seNext.cLinesPrefetched = 0; //We've jumped to some other address, so start fetching again!
                if (`VERBOSE) $display(", old stride is broken, but tolerate it! Keep old stride: %h", se.stride);
            end
            else begin
                seNext.state = TRANSIENT;
                seNext.stride = observedStride;
                if (`VERBOSE) $display(", old stride is broken! New stride: %h", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else
            if (`VERBOSE) $display("");
        
        strideEntryForPrefetch.enq(tuple3(seNext, addr, pcHash));
    endrule

    rule createPrefetchRequests;
        match {.se, .addr, .pcHash} = strideEntryForPrefetch.first;
        //If this rule is looping, then we'll have a valid cLinesPrefetchedLatest
        Bit#(4) cLinesPrefetched = fromMaybe(se.cLinesPrefetched, cLinesPrefetchedLatest);

        if (stateAtLeastSteady(se.state) && 
            cLinesPrefetched != 
            cLinesAheadToPrefetch(se.state, se.stride)) begin
            //can prefetch
            
            Bit#(13) strideToUse;
            Bit#(13) cLineSize = fromInteger(valueof(DataSz));
            if (se.stride[12] == 1 && se.stride > -cLineSize) begin
                //stride is negative and jumps less than one cline
                strideToUse = -cLineSize;
            end
            else if (se.stride[12] == 0 && se.stride < cLineSize) begin
                //stride is positive and jumps less than one cline
                strideToUse = cLineSize;
            end 
            else begin
                strideToUse = se.stride;
            end

            let reqAddr = addr + 
                (signExtend(strideToUse) * zeroExtend(cLinesPrefetched + 1));

            addrToPrefetch.enq(reqAddr);
            // We will still be processing this StrideEntry next cycle, 
            // so hold off any potential read requests until we do a writeback
            holdReadReq.send();
            cLinesPrefetchedLatest <= Valid(cLinesPrefetched + 1);
            if (`VERBOSE) $display("%t Stride Prefetcher getNextPrefetchAddr requesting %h for entry %h", $time, reqAddr, pcHash[7:0]);
        end
        else begin
            //cant prefetch
            if (`VERBOSE) $display("%t Stride Prefetcher no possible prefetch for entry %h", $time, strideTableIndexT'(truncate(pcHash)));
            strideEntryForPrefetch.deq;
            se.cLinesPrefetched = cLinesPrefetched;
            cLinesPrefetchedLatest <= Invalid;
            strideTable.wrReq(truncate(pcHash), se);
        end
    endrule

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss);
        memAccesses.enq(tuple3 (addr, pcHash, hitMiss));
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
        addrToPrefetch.deq;
        return addrToPrefetch.first;
    endmethod

endmodule


interface PrefetcherVector#(numeric type size);
    method ActionValue#(Tuple2#(Addr, Bit#(TLog#(size)))) getNextPrefetchAddr;
    method Action reportAccess(Bit#(TLog#(size)) idx, Addr addr, HitOrMiss hitMiss);
endinterface

module mkPrefetcherVector#(module#(Prefetcher) mkPrefetcher)
(
    PrefetcherVector#(size)
) provisos (
    Alias#(idxT, Bit#(TLog#(size)))
);
    Vector#(size, Prefetcher) prefetchers <- replicateM(mkPrefetcher);
    Fifo#(1, Tuple2#(Addr, idxT)) prefetchRq <- mkBypassFifo;

    function XBarDstInfo#(Bit#(0),Tuple2#(Addr, idxT)) convertPrefetchRq(idxT item, Addr a);
        return XBarDstInfo { 
            idx: 0,
            data: tuple2(a, item)
        };
    endfunction
    function Get#(Addr) reqGet(Prefetcher p) = toGet(p.getNextPrefetchAddr);
    mkXBar(convertPrefetchRq, map(reqGet, prefetchers), vec(toPut(prefetchRq)));

    method ActionValue#(Tuple2#(Addr, idxT)) getNextPrefetchAddr;
        prefetchRq.deq;
        return prefetchRq.first;
    endmethod

    method Action reportAccess(idxT idx, Addr addr, HitOrMiss hitMiss);
        prefetchers[idx].reportAccess(addr, hitMiss);
    endmethod
endmodule

module mkL1IPrefetcher(Prefetcher);
`ifdef INSTR_PREFETCHER_IN_L1
    `ifdef INSTR_PREFETCHER_NEXT_LINE_ON_ALL
        Parameter#(1) lines <- mkParameter;
        let m <- mkNextLineOnAllPrefetcher(lines);
    `elsif INSTR_PREFETCHER_NEXT_LINE_ON_MISS
        Parameter#(1) lines <- mkParameter;
        let m <-  mkNextLineOnMissPrefetcher(lines);
    `elsif INSTR_PREFETCHER_SINGLE_WINDOW
        Parameter#(3) lines <- mkParameter;
        let m <-  mkSingleWindowPrefetcher(lines);
    `elsif INSTR_PREFETCHER_SINGLE_WINDOW_TARGET
        Parameter#(16) numLastRequests <- mkParameter;
        Parameter#(1) cacheLinesInRange <- mkParameter;
        let m <-  mkSingleWindowTargetPrefetcher(numLastRequests, cacheLinesInRange);
    `elsif INSTR_PREFETCHER_MULTI_WINDOW
        Parameter#(4) numWindows <- mkParameter;
        Parameter#(2) lines <- mkParameter;
        let m <-  mkMultiWindowPrefetcher(numWindows, lines);
    `elsif INSTR_PREFETCHER_MULTI_WINDOW_TARGET
        Parameter#(4) numWindows <- mkParameter;
        Parameter#(16) numLastRequests <- mkParameter;
        Parameter#(16) cacheLinesInRange <- mkParameter;
        let m <-  mkMultiWindowTargetPrefetcher(numWindows, numLastRequests, cacheLinesInRange);
    `endif
    //let m <- mkAlwaysRequestPrefetcher;
    //let m <- mkPrintPrefetcher;
`else
    let m <- mkDoNothingPrefetcher;
`endif
    return m;
endmodule

module mkLLIPrefetcherInL1I(Prefetcher);
`ifdef INSTR_PREFETCHER_IN_L1LL
    `ifdef INSTR_PREFETCHER_NEXT_LINE_ON_ALL
        Parameter#(1) lines <- mkParameter;
        let m <-  mkNextLineOnAllPrefetcher(lines);
    `elsif INSTR_PREFETCHER_NEXT_LINE_ON_MISS
        Parameter#(1) lines <- mkParameter;
        let m <-  mkNextLineOnMissPrefetcher(lines);
    `elsif INSTR_PREFETCHER_SINGLE_WINDOW
        Parameter#(3) lines <- mkParameter;
        let m <-  mkSingleWindowL1LLPrefetcher(lines);
    `elsif INSTR_PREFETCHER_SINGLE_WINDOW_TARGET
        Parameter#(16) numLastRequests <- mkParameter;
        Parameter#(1) cacheLinesInRange <- mkParameter;
        let m <-  mkSingleWindowTargetPrefetcher(numLastRequests, cacheLinesInRange);
    `elsif INSTR_PREFETCHER_MULTI_WINDOW
        Parameter#(4) numWindows <- mkParameter;
        Parameter#(2) lines <- mkParameter;
        let m <-  mkMultiWindowPrefetcher(numWindows, lines);
    `elsif INSTR_PREFETCHER_MULTI_WINDOW_TARGET
        Parameter#(4) numWindows <- mkParameter;
        Parameter#(16) numLastRequests <- mkParameter;
        Parameter#(3) cacheLinesInRange <- mkParameter;
        let m <-  mkMultiWindowTargetPrefetcher(numWindows, numLastRequests, cacheLinesInRange);
    `endif
    //let m <- mkAlwaysRequestPrefetcher;
    //let m <- mkPrintPrefetcher;
`else
    let m <- mkDoNothingPrefetcher;
`endif
    return m;
endmodule

module mkLLIPrefetcher(Prefetcher);
`ifdef INSTR_PREFETCHER_IN_LL
    `ifdef INSTR_PREFETCHER_NEXT_LINE_ON_ALL
        Parameter#(1) lines <- mkParameter;
        let m <-  mkNextLineOnAllPrefetcher(lines);
    `elsif INSTR_PREFETCHER_NEXT_LINE_ON_MISS
        Parameter#(1) lines <- mkParameter;
        let m <-  mkNextLineOnMissPrefetcher(lines);
    `elsif INSTR_PREFETCHER_SINGLE_WINDOW
        Parameter#(3) lines <- mkParameter;
        let m <-  mkSingleWindowPrefetcher(lines);
    `elsif INSTR_PREFETCHER_SINGLE_WINDOW_TARGET
        Parameter#(16) numLastRequests <- mkParameter;
        Parameter#(1) cacheLinesInRange <- mkParameter;
        let m <-  mkSingleWindowTargetPrefetcher(numLastRequests, cacheLinesInRange);
    `elsif INSTR_PREFETCHER_MULTI_WINDOW
        Parameter#(4) numWindows <- mkParameter;
        Parameter#(2) lines <- mkParameter;
        let m <-  mkMultiWindowPrefetcher(numWindows, lines);
    `elsif INSTR_PREFETCHER_MULTI_WINDOW_TARGET
        Parameter#(4) numWindows <- mkParameter;
        Parameter#(16) numLastRequests <- mkParameter;
        Parameter#(3) cacheLinesInRange <- mkParameter;
        let m <-  mkMultiWindowTargetPrefetcher(numWindows, numLastRequests, cacheLinesInRange);
    `endif
    //let m <- mkAlwaysRequestPrefetcher;
    //let m <- mkPrintPrefetcher;
`else
    let m <- mkDoNothingPrefetcher;
`endif
    return m;
endmodule

module mkL1DPrefetcher(PCPrefetcher);
`ifdef DATA_PREFETCHER_IN_L1
    `ifdef DATA_PREFETCHER_BLOCK
        Parameter#(1) numLinesEachWay <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkBlockPrefetcher(numLinesEachWay));
    `elsif DATA_PREFETCHER_STRIDE
        //let m <- mkStridePCPrefetcher;
        let m <- mkStride2PCPrefetcher;
    `elsif DATA_PREFETCHER_STRIDE_ADAPTIVE
        Parameter#(512) strideTableSize <- mkParameter;
        Parameter#(1) cLinesPrefetchMin <- mkParameter;
        Parameter#(2) cLinesSmallStridePrefetchMax <- mkParameter;
        Parameter#(4) cLinesBigStridePrefetchMax <- mkParameter;
        let m <- mkStrideAdaptivePCPrefetcher(
            strideTableSize, 
            cLinesPrefetchMin, 
            cLinesSmallStridePrefetchMax, 
            cLinesBigStridePrefetchMax);
    `elsif DATA_PREFETCHER_MARKOV
        Parameter#(2) maxChainLength <- mkParameter;
        Parameter#(2048) narrowEntries <- mkParameter;
        Parameter#(128) wideEntries <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkMarkovPrefetcher(maxChainLength, narrowEntries, wideEntries));
    `elsif DATA_PREFETCHER_MARKOV_ON_HIT
        Parameter#(1) maxChainLength <- mkParameter;
        Parameter#(32) numLastRequestsTracked <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkMarkovOnHitPrefetcher(maxChainLength, numLastRequestsTracked));
    `elsif DATA_PREFETCHER_MARKOV_ON_HIT_2
        Parameter#(1) maxChainLength <- mkParameter;
        Parameter#(32) numLastRequestsTracked <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkMarkovOnHit2Prefetcher(maxChainLength, numLastRequestsTracked));
    `endif
    //let m <- mkPCPrefetcherAdapter(mkAlwaysRequestPrefetcher);
`else 
    let m <- mkPCPrefetcherAdapter(mkDoNothingPrefetcher);
`endif
    return m;
endmodule

module mkLLDPrefetcherInL1D(PCPrefetcher);
`ifdef DATA_PREFETCHER_IN_L1LL
    `ifdef DATA_PREFETCHER_BLOCK
        Parameter#(1) numLinesEachWay <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkBlockPrefetcher(numLinesEachWay));
    `elsif DATA_PREFETCHER_STRIDE
        let m <- mkStride2PCPrefetcher;
    `elsif DATA_PREFETCHER_STRIDE_ADAPTIVE
        Parameter#(512) strideTableSize <- mkParameter;
        Parameter#(1) cLinesPrefetchMin <- mkParameter;
        Parameter#(2) cLinesSmallStridePrefetchMax <- mkParameter;
        Parameter#(4) cLinesBigStridePrefetchMax <- mkParameter;
        let m <- mkStrideAdaptivePCPrefetcher(
            strideTableSize, 
            cLinesPrefetchMin, 
            cLinesSmallStridePrefetchMax, 
            cLinesBigStridePrefetchMax);
    `elsif DATA_PREFETCHER_MARKOV
        Parameter#(2) maxChainLength <- mkParameter;
        Parameter#(2048) narrowEntries <- mkParameter;
        Parameter#(128) wideEntries <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkMarkovPrefetcher(maxChainLength, narrowEntries, wideEntries));
    `elsif DATA_PREFETCHER_MARKOV_ON_HIT
        Parameter#(1) maxChainLength <- mkParameter;
        Parameter#(32) numLastRequestsTracked <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkMarkovOnHitPrefetcher(maxChainLength, numLastRequestsTracked));
    `elsif DATA_PREFETCHER_MARKOV_ON_HIT_2
        Parameter#(1) maxChainLength <- mkParameter;
        Parameter#(32) numLastRequestsTracked <- mkParameter;
        let m <- mkPCPrefetcherAdapter(mkMarkovOnHit2Prefetcher(maxChainLength, numLastRequestsTracked));
    `endif
    //let m <- mkPCPrefetcherAdapter(mkAlwaysRequestPrefetcher);
`else 
    let m <- mkPCPrefetcherAdapter(mkDoNothingPrefetcher);
`endif
    return m;
endmodule

module mkLLDPrefetcher(Prefetcher);
`ifdef DATA_PREFETCHER_IN_LL
    `ifdef DATA_PREFETCHER_BLOCK
        Parameter#(1) numLinesEachWay <- mkParameter;
        let m <- mkBlockPrefetcher(numLinesEachWay);
    `elsif DATA_PREFETCHER_STRIDE
        doAssert(False, "Illegal data prefetcher type for LL cache!");
    `elsif DATA_PREFETCHER_STRIDE_ADAPTIVE
        doAssert(False, "Illegal data prefetcher type for LL cache!");
    `elsif DATA_PREFETCHER_MARKOV
        Parameter#(2) maxChainLength <- mkParameter;
        Parameter#(2048) narrowEntries <- mkParameter;
        Parameter#(128) wideEntries <- mkParameter;
        let m <- mkMarkovPrefetcher(maxChainLength, narrowEntries, wideEntries);
    `elsif DATA_PREFETCHER_MARKOV_ON_HIT
        Parameter#(1) maxChainLength <- mkParameter;
        Parameter#(32) numLastRequestsTracked <- mkParameter;
        let m <- mkMarkovOnHitPrefetcher(maxChainLength, numLastRequestsTracked);
    `elsif DATA_PREFETCHER_MARKOV_ON_HIT_2
        Parameter#(1) maxChainLength <- mkParameter;
        Parameter#(32) numLastRequestsTracked <- mkParameter;
        let m <- mkMarkovOnHit2Prefetcher(maxChainLength, numLastRequestsTracked);
    `endif
    //let m <- mkPCPrefetcherAdapter(mkAlwaysRequestPrefetcher);
`else 
    let m <- mkDoNothingPrefetcher;
`endif
    return m;
endmodule