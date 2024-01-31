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

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif

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

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif

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

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif

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

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return unpack(0);
    endmethod
`endif
endmodule