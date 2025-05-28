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
import RWBramCoreSequential::*;
import ConfigReg::*;
import SpecialRegs::*;
import CHERICap::*;
import CHERICC_Fat::*;
import PerformanceMonitor::*;
import MemoryTypes::*;

`define VERBOSE True

//If the capability is small, prefetches all lines within the capability
module mkAllInCapPrefetcher#(Parameter#(maxCapSizeToPrefetch) _)(CheriPCPrefetcher) provisos (
    NumAlias#(pageIndexBits, 6), //assume 4k pages
    Alias#(pageAddressT, Bit#(TSub#(LineAddrSz, pageIndexBits)))
);
    Reg#(LineAddr) prefetchNext <- mkReg(0);
    Reg#(LineAddr) prefetchEnd <- mkReg(0); //inclusive
    Reg#(LineAddr) originalMiss <- mkReg(0);
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (1, unpack (0));

    rule skipOriginalMiss if (prefetchNext == originalMiss);
        prefetchNext <= prefetchNext + 1;
    endrule
    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        if (hitMiss == MISS && boundsLength != 0) begin
            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = 1;
            LineAddr cLinesInBounds = truncateLSB(boundsLength) + 1;
            Addr boundsBase = addr-boundsOffset;
            Addr boundsTop = addr+(boundsLength-boundsOffset-1);
            if (`VERBOSE) $display("%t Prefetcher report MISS %h (bottom: %h, top: %h)", 
                $time, addr, boundsBase, boundsTop);
            if (boundsLength <= fromInteger(valueof(maxCapSizeToPrefetch))) begin
                evt.evt_1 = 1;
                evt.evt_2 = truncate(boundsLength);
                pageAddressT basePage = truncateLSB(boundsBase);
                pageAddressT addrPage = truncateLSB(addr);
                pageAddressT topPage = truncateLSB(boundsTop);
                if (basePage != addrPage) begin
                    //If base is in a different page, fetch from bottom of this page.
                    boundsBase = Addr'{addrPage, 0};
                    evt.evt_3 = 1;
                end
                if (topPage != addrPage) begin
                    //If base is in a different page, fetch until the top of this page.
                    boundsTop = Addr'{addrPage, 12'hfff};
                    evt.evt_3 = 1;
                end
                prefetchNext <= getLineAddr(boundsBase);
                prefetchEnd <= getLineAddr(boundsTop);
                originalMiss <= getLineAddr(addr);
                if (`VERBOSE) $display("%t Prefetcher MISS bounds length %d, so set up prefetches from %h to %h", 
                    $time, boundsLength, boundsBase, boundsTop);
            end
            perf_events[0] <= evt;
        end
        else 
            if (`VERBOSE) $display("%t Prefetcher report HIT %h", $time, addr);
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr
        if (prefetchNext <= prefetchEnd && prefetchNext != originalMiss);
        
        prefetchNext <= prefetchNext + 1;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time,Addr'{prefetchNext, '0});
        return tuple3(Addr'{prefetchNext, '0}, almightyCap, ?);

    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return perf_events[0];
    endmethod
`endif

endmodule

typedef enum {
  INIT = 2'd0, TRANSIENT = 2'd1, STEADY = 2'd2, NO_PRED = 2'd3
} StrideState deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(12) lastAddr; 
    Int#(12) stride;
    Bit#(4) cLinesPrefetched; //Stores how many cache lines have been prefetched for this entry
    StrideState state;
} StrideEntry deriving (Bits, Eq, FShow);

//Use virtual base of bounds to index into table 
module mkCheriStridePrefetcher#(DTlbToPrefetcher toTlb, Parameter#(strideTableSize) _, Parameter#(cLinesAheadToPrefetch) __, 
    Parameter#(pcInHash) ___, Parameter#(boundsInHash) ____)(CheriPCPrefetcher)
provisos(
    Alias#(strideTableIndexT, Bit#(TLog#(strideTableSize))),
    Add#(a__, TLog#(strideTableSize), 16),
    Add#(1, c__, TDiv#(16, TLog#(strideTableSize))),
    Add#(b__, 16, TMul#(TDiv#(16, TLog#(strideTableSize)), TLog#(strideTableSize)))
    );
    RWBramCore#(strideTableIndexT, StrideEntry) strideTable <- mkRWBramCoreForwarded;
    FIFOF#(Tuple5#(Addr, Bit#(16), HitOrMiss, Addr, Addr)) memAccesses <- mkSizedBypassFIFOF(16);
    Reg#(Tuple5#(Addr, Bit#(16), HitOrMiss, Addr, Addr)) rdRespEntry <- mkReg(?);

    Bool trainOnLineAddr = False;
    Fifo#(8, Addr) vaddrToTlb <- mkOverflowPipelineFifo;
    Fifo#(8, Addr) addrToPrefetch <- mkOverflowPipelineFifo;
    FIFO#(Tuple5#(StrideEntry, Addr, Bit#(16), Addr, Addr)) strideEntryForPrefetch <- mkBypassFIFO();
    Reg#(Maybe#(Bit#(4))) cLinesPrefetchedLatest <- mkReg(?);
    PulseWire holdReadReq <- mkPulseWire;
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (3, unpack (0));

    rule sendReadReq if (!holdReadReq);
        match {.addr, .boundsHash, .hitMiss, .bot, .top} = memAccesses.first;
        if (`VERBOSE) $display("%t Sending read req for %h!", $time, boundsHash);
        strideTable.rdReq(hash(boundsHash));
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
        match {.addr, .boundsHash, .hitMiss, .bot, .top} = rdRespEntry;
        strideTableIndexT index = hash(boundsHash);
        StrideEntry se = strideTable.rdResp;
        strideTable.deqRdResp;
        StrideEntry seNext = se;
        Int#(12) observedStride = unpack(addr[11:0] - se.lastAddr);
        if (`VERBOSE) $display("%t Stride Prefetcher updateStrideEntry ", $time,
            fshow(hitMiss), " ", addr,
            ". Entry ", index, " state is ", fshow(se.state), "\n");
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
        
        strideEntryForPrefetch.enq(tuple5(seNext, addr, boundsHash, bot, top));
    endrule

    rule createPrefetchRequests;
        match {.se, .addr, .boundsHash, .bot, .top} = strideEntryForPrefetch.first;
        //If this rule is looping, then we'll have a valid cLinesPrefetchedLatest
        Bit#(4) cLinesPrefetched = fromMaybe(se.cLinesPrefetched, cLinesPrefetchedLatest);

        Int#(16) cLineSize = fromInteger(valueof(DataSz));
        Int#(16) strideToUse = signExtend(se.stride);
        if (abs(strideToUse) < cLineSize) begin
            strideToUse = (strideToUse < 0) ? -cLineSize : cLineSize; 
        end
        Bit#(16) jumpDist = pack(strideToUse) * zeroExtend(cLinesPrefetched+1);
        Addr reqAddr = addr + signExtend(jumpDist);
        LineAddr reqAddrLine = truncateLSB(reqAddr);
        reqAddr = {reqAddrLine, (strideToUse >= 0) ? 6'd0 : 6'h3f};
        Bit#(16) minimumJumpDist = truncate(reqAddr - addr);
        //$display("addr: %h new reqAddr %h old jumpdist %h new jumpDist %h", addr, reqAddr, jumpDist, minimumJumpDist);
        Addr jumpDistLarge = signExtend(minimumJumpDist);
        Bool isInCapBounds = (jumpDist[15]==0) ? signExtend(minimumJumpDist) <= top : -signExtend(minimumJumpDist) <= bot;
        //(signExtend(jumpDist) > -bot) && (signExtend(jumpDist) < top);
        $display("Potential prefetch (%h, %h) is in cap bounds (%h and %h)? %b", reqAddr, jumpDistLarge, bot, top, isInCapBounds);
        if (se.state == STEADY && 
            cLinesPrefetched != 
            fromInteger(valueof(cLinesAheadToPrefetch)) &&
            reqAddr[63:12] == addr[63:12] && //Check if same page
            isInCapBounds
        ) begin
            //can prefetch

            //vaddrToTlb.enq(reqAddr);
            addrToPrefetch.enq(reqAddr);
            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = (bot+top >= 4096) ? 1 : 0;
            evt.evt_1 = (bot+top >= 131072) ? 1 : 0;
            evt.evt_2 = 1;
            //if (isInCapBounds) begin
            if (bot+top >= 131072*16) begin
                evt.evt_3 = 1;
            end
            perf_events[0] <= evt;
            // We will still be processing this StrideEntry next cycle, 
            // so hold off any potential read requests until we do a writeback
            holdReadReq.send();
            cLinesPrefetchedLatest <= Valid(cLinesPrefetched + 1);
            if (`VERBOSE) $display("%t Stride Prefetcher DTLB request vaddr %h for entry %h", $time, reqAddr, strideTableIndexT'(hash(boundsHash)));
        end
        else begin
            //cant prefetch
            if (`VERBOSE) $display("%t Stride Prefetcher no possible prefetch for entry %h", $time, strideTableIndexT'(hash(boundsHash)));
            strideEntryForPrefetch.deq;
            se.cLinesPrefetched = cLinesPrefetched;
            cLinesPrefetchedLatest <= Invalid;
            strideTable.wrReq(hash(boundsHash), se);
        end
    endrule

    /*
    rule doTlbLookup if (True);
        let vaddr = vaddrToTlb.first;
        vaddrToTlb.deq;
        CapPipe start = almightyCap;
        let cp = setAddr(start, vaddr);
        toTlb.prefetcherReq(cp.value);
        sendTlbReq <= sendTlbReq + 1;
    endrule

    rule getTlbResp;
        let resp = toTlb.prefetcherResp;
        toTlb.deqPrefetcherResp;
        EventsPrefetcher evt = unpack(0);
        evt.evt_1 = 1;
        perf_events[1] <= evt;
        if (`VERBOSE) $display("%t prefetcher got TLB response: ", $time, fshow(resp));
        if (!resp.haveException) begin
            addrToPrefetch.enq(resp.paddr);
        end
    endrule
    */

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        Bit#(16) finalHash = 0;
        if (valueOf(boundsInHash)==1) begin
            finalHash = finalHash ^ hash(boundsVirtBase);
            finalHash = finalHash ^ hash(boundsLength);
            finalHash = finalHash ^ hash(capPerms);
        end
        if (valueOf(pcInHash)==1)
            finalHash = finalHash ^ hash(pcHash);
        Addr topCapGap = (boundsLength == 0) ? -1 : boundsLength-boundsOffset-1;
        Addr vaddr = boundsVirtBase+boundsOffset;
        if (`VERBOSE) $display("%t Prefetcher reportAccess %h %h %h perms: %h, hash: %h pchash: %h", $time, addr, boundsLength, boundsVirtBase, capPerms, finalHash, pcHash);
        if (trainOnLineAddr) addr = {addr[63:6], 6'b0}; //zero LSBs if training on lineAddresses
        memAccesses.enq(tuple5 (addr, finalHash, hitMiss, boundsOffset, topCapGap));
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr;
        EventsPrefetcher evt = unpack(0);
        evt.evt_4 = 1;
        perf_events[2] <= evt;
        addrToPrefetch.deq;
        let addr = addrToPrefetch.first;
        if (`VERBOSE) $display("%t Stride Prefetcher getNextPrefetchAddr paddr %h", $time, addr);
        return tuple3(addr, almightyCap, ?);
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        let evt = EventsPrefetcher {
            evt_0: perf_events[0].evt_0,
            evt_1: perf_events[0].evt_1,
            evt_2: perf_events[0].evt_2,
            evt_3: perf_events[0].evt_3,
            evt_4: perf_events[0].evt_4
        };
        return evt;
    endmethod
`endif

endmodule

typedef enum {
  NOTUSED = 2'd2, USED1 = 2'd1, USED2 = 2'd0, USED3 = 2'd3
} LineState deriving (Bits, Eq, FShow);

typedef struct {
    Vector#(numEntries, LineState) bitmap;
} BitmapEntry#(numeric type numEntries) deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(tagBits) tag;
    Bool prefetched;
} FilterEntry#(numeric type tagBits) deriving (Bits, Eq, FShow);

module mkCapBitmapPrefetcherOld#(Parameter#(maxCapSizeToTrack) _, Parameter#(bitmapTableSize) __, 
        Parameter#(filterTableSize) ___, Parameter#(inverseDecayChance) ____)(CheriPCPrefetcher) provisos (
    Add#(a__, TLog#(TDiv#(maxCapSizeToTrack, 64)), 58),
    NumAlias#(pageIndexBits, 6), //assume 4k pages
    Alias#(pageAddressT, Bit#(TSub#(LineAddrSz, pageIndexBits))),
    NumAlias#(tagBits, 16),
    NumAlias#(pfQueueSize, 16),
    NumAlias#(linesInPage, 64),
    NumAlias#(bitmapLength, TDiv#(maxCapSizeToTrack, 64)),
    Alias#(bitmapIndexT, Bit#(TLog#(bitmapLength))),
    Alias#(bitmapTableIdxT, Bit#(TLog#(bitmapTableSize))),
    Alias#(filterTableIdxT, Bit#(TLog#(filterTableSize))),
    Alias#(filterTableIdxTagT, Bit#(TAdd#(TLog#(filterTableSize), tagBits))),
    Alias#(bitmapEntryT, BitmapEntry#(bitmapLength)),
    Alias#(filterEntryT, FilterEntry#(tagBits)),
    Alias#(pageBitmapT, Vector#(64, LineState)),

    Add#(1, b__, TDiv#(64, TAdd#(TLog#(filterTableSize), 16))),
    Add#(c__, 64, TMul#(TDiv#(64, TAdd#(TLog#(filterTableSize), 16)), TAdd#(TLog#(filterTableSize), 16))),
    Add#(d__, 52, TMul#(TDiv#(52, TAdd#(TLog#(filterTableSize), 16)), TAdd#(TLog#(filterTableSize), 16))),
    Add#(1, f__, TDiv#(64, TLog#(bitmapTableSize))),
    Add#(g__, 64, TMul#(TDiv#(64, TLog#(bitmapTableSize)),TLog#(bitmapTableSize))), 
    Add#(1, e__, TDiv#(52, TAdd#(TLog#(filterTableSize), 16))),
    Add#(h__, 16, TMul#(TDiv#(16, TLog#(bitmapTableSize)), TLog#(bitmapTableSize))),
    Add#(1, i__, TDiv#(16, TLog#(bitmapTableSize))),
    Add#(j__, 2, TLog#(bitmapTableSize))

);
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (4, unpack (0));
    RWBramCore#(bitmapTableIdxT, bitmapEntryT) bt <- mkRWBramCoreForwarded();
    RWBramCore#(filterTableIdxT, filterEntryT) ft <- mkRWBramCoreForwarded();
    Fifo#(pfQueueSize, LineAddr) pfQueue <- mkOverflowPipelineFifo;
    Fifo#(1, Tuple7#(Addr, HitOrMiss, LineAddr, Addr, bitmapTableIdxT, filterTableIdxTagT, Addr)) dataForRdResp <- mkPipelineFifo;
    Fifo#(4, Tuple3#(Vector#(linesInPage, Bool), pageAddressT, UInt#(8))) issuePrefetchesQueue <- mkBypassFifo;
    Reg#(Tuple2#(pageAddressT, UInt#(8))) dataForIssuePrefetches <- mkConfigReg(?);
    Reg#(Vector#(linesInPage, Bool)) canPrefetch <- mkConfigReg(replicate(False));
    Reg#(Bit#(8)) randomCounter <- mkConfigReg(0);

    function LineState upgrade(LineState st) = 
        case (st)
            NOTUSED: USED1;
            USED1: USED2;
            USED2: USED3;
            USED3: USED3;
        endcase;

    function LineState downgrade(LineState st) =
        case (st)
            NOTUSED: NOTUSED;
            USED1: NOTUSED;
            USED2: USED1;
            USED3: USED2;
        endcase;

    rule incrRandomCounter;
        if (randomCounter == fromInteger(valueof(inverseDecayChance))-1)
            randomCounter <= 0;
        else
            randomCounter <= randomCounter + 1;
    endrule

    rule processRdResp;
        bitmapEntryT bte = bt.rdResp;
        bt.deqRdResp;
        filterEntryT fte = ft.rdResp;
        ft.deqRdResp;
        let {accessAddr, hitMiss, boundsOffset, boundsVirtBase, btIdx, ftIdxTag, boundsLength} = dataForRdResp.first;
        LineAddr accessLineAddr = truncateLSB(accessAddr);
        dataForRdResp.deq;

        Bit#(tagBits) ftTag = truncateLSB(ftIdxTag);
        if (hitMiss == MISS && (ftTag != fte.tag || fte.prefetched == False)) begin
            //Update filter table
            fte.tag = ftTag;
            fte.prefetched = True;
            ft.wrReq(truncate(ftIdxTag), fte); 

            //Find cache lines in current page to possibly prefetch
            pageAddressT pa = truncateLSB(accessAddr);
            LineAddr pageStartAddr = {pa, '0};
            LineAddr pageStartCapOffset = boundsOffset - (accessLineAddr - pageStartAddr);
            Vector#(linesInPage, Bool) canPrefetchVec = replicate(False);
            Vector#(linesInPage, Bool) atLeastUsed2 = replicate(False);
            for (Integer i = 0; i < valueOf(linesInPage); i = i + 1) begin
            //Possible bug here with >= 0
                if (fromInteger(i) != (accessLineAddr - pageStartAddr) && 
                    fromInteger(i) + pageStartCapOffset >= 0 && fromInteger(i) + pageStartCapOffset < fromInteger(valueof(bitmapLength))) begin
                    LineState st = bte.bitmap[fromInteger(i)+pageStartCapOffset];
                    canPrefetchVec[i] = st == USED3;//|| st == USED2;
                    atLeastUsed2[i] = st == USED1 || st == USED2 || st == USED3;
                end
            end
            if (`VERBOSE) $display("%t prefetcher:processRdResp MISS offset %h in new cap %h (for cap idx %h), found %d possible prefetches!", 
                $time, boundsOffset, ftIdxTag, btIdx, countElem(True, canPrefetchVec));
            if (`VERBOSE) $display("%t prefetcher:processRdResp canPrefetchVec: ", 
                $time, fshow(canPrefetchVec));

            issuePrefetchesQueue.enq(tuple3(canPrefetchVec, pa, unpack(truncate(accessLineAddr - pageStartAddr))));

            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = 1;
            evt.evt_2 = (boundsLength <= 1024) ? 0 : extend(pack(countElem(True, canPrefetchVec)));
            evt.evt_1 = extend(pack(countElem(True, canPrefetchVec)));
            //evt.evt_2 = extend(pack(countElem(True, canPrefetchVec)));
            perf_events[1] <= evt;
        end
        
        //NB: Change this for LLC prefetching -- then L1 acts as filter, so can upgrade and downgrade on hits too!
        //For L1, will get many hits for the same cache line, so only want to do stuff for misses.
        if (hitMiss == MISS) begin
            //Downgrade all states with probability 1/inverseDecayChance
            if (randomCounter == 0) begin
                for (Integer i = 0; i < valueof(bitmapLength); i = i + 1) begin
                        bte.bitmap[i] = downgrade(bte.bitmap[i]);
                end
                if (`VERBOSE) $display("%t prefetcher:processRdResp downgrading lines in cap %h!. Status now: ", 
                $time, btIdx);
                for (Integer i = 0; i < valueof(bitmapLength); i = i + 1) begin
                    if (`VERBOSE) $write(" ", fshow(bte.bitmap[i]));
                end
                
            end
            //Update state of cache line in bitmap
            //LineAddr accessLineAddr = truncateLSB(addr);
            EventsPrefetcher evt = unpack(0);
            evt.evt_3 = 1;
            perf_events[2] <= evt;

            bitmapIndexT bitmapIdx = truncate(boundsOffset);
            LineState state = bte.bitmap[bitmapIdx];
            LineState nextState = upgrade(state);
            bte.bitmap[bitmapIdx] = nextState;
            if (`VERBOSE) $display("%t prefetcher:processRdResp upgrading offset %h in cap %h to ", $time, boundsOffset, btIdx, fshow(nextState));
            bt.wrReq(btIdx, bte);
        end
    endrule

    rule issuePrefetchesQToReg;
        if (canPrefetch == replicate(False) || !issuePrefetchesQueue.notFull) begin
            issuePrefetchesQueue.deq;
            let {canPrefetchVec, pa, accessOffset} = issuePrefetchesQueue.first;
            canPrefetch <= canPrefetchVec;
            dataForIssuePrefetches <= tuple2(pa, accessOffset);
        end
    endrule

    rule issuePrefetches;
        let {pageStartAddr, accessOffset} = dataForIssuePrefetches;
        Vector#(linesInPage, Bool) canPrefetchAbove = replicate(False);
        Vector#(linesInPage, Bool) canPrefetchBelow = replicate(False);
        for (Integer i = 1; i < valueof(linesInPage); i = i + 1) begin
            if (fromInteger(i)+accessOffset < fromInteger(valueof(linesInPage)))
                canPrefetchAbove[i] = canPrefetch[fromInteger(i)+accessOffset];
        end
        for (Integer i = 1; i < valueof(linesInPage); i = i + 1) begin
            //Check for underflow
            if (accessOffset - fromInteger(i) < fromInteger(valueOf(linesInPage)))
                canPrefetchBelow[i] = canPrefetch[accessOffset - fromInteger(i)];
        end

        let canPrefetchAboveIdx = findElem(True, canPrefetchAbove);
        let canPrefetchBelowIdx = findElem(True, canPrefetchBelow);
        Maybe#(UInt#(6)) prefetchIdx = Invalid;
        if (canPrefetchAboveIdx matches tagged Valid .aboveIdx) begin
            if (canPrefetchBelowIdx matches tagged Valid .belowIdx) begin
                //Prefetch the closest cache lines first
                if (aboveIdx <= belowIdx) 
                    prefetchIdx = tagged Valid (truncate(accessOffset)+aboveIdx);
                else 
                    prefetchIdx = tagged Valid (truncate(accessOffset)-belowIdx);
            end
            else begin
                prefetchIdx = tagged Valid (truncate(accessOffset)+aboveIdx);
            end
        end
        else if (canPrefetchBelowIdx matches tagged Valid .belowIdx) begin
            prefetchIdx = tagged Valid (truncate(accessOffset)-belowIdx);
        end
        
        if (prefetchIdx matches tagged Valid .idx) begin
            //if (`VERBOSE) $display("%t prefetcher:issuePrefetches canPrefetch at start: ", $time, fshow(canPrefetch));
            let canPrefetchVec = canPrefetch;
            canPrefetchVec[idx] = False;
            canPrefetch <= canPrefetchVec;
            LineAddr toPrefetch = {pageStartAddr, '0} + pack(extend(idx));
            if (`VERBOSE) $display("%t prefetcher:issuePrefetches %h", $time, Addr'{toPrefetch, '0});
            pfQueue.enq(extend(toPrefetch));

            EventsPrefetcher evt = unpack(0);
            evt.evt_4 = 1;
            perf_events[3] <= evt;
        end
    endrule

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        if (boundsLength > 64 && boundsLength <= fromInteger(valueOf(maxCapSizeToTrack))) begin
            $display("%t prefetcher:reportAccess %h with bounds length %d base %h offset %d", $time, addr, boundsLength, boundsVirtBase, boundsOffset);
            //Not all objects are aligned in the same way, so we separate the training bitmaps for objects that are aligned differently
            //Otherwise, one 8-byte field in different objects might land in 2 different cache lines, 
            //meaning both cache lines would be prefetched every time.
            //As this reduces the amount of training data, this is done partially, grouping objects with same 16byte alignment together
            //(Although it is likely malloc allocates all objects with a 16-byte aligned start anyway)
            Bit#(2) capStart16byteOffset = boundsVirtBase[5:4]; 
            bitmapTableIdxT bidx = hash(boundsLength) ^ extend(capStart16byteOffset);
            bt.rdReq(bidx);
            pageAddressT pa = truncateLSB(addr);
            filterTableIdxTagT fidx = hash(boundsVirtBase) ^ hash(pa);
            ft.rdReq(truncate(fidx));
            Bit#(6) offsetInLine = truncate(boundsVirtBase);
            //boundsOffset2 tracks the idx of the cache line in the capability.
            LineAddr boundsOffset2 = truncateLSB(boundsOffset+extend(offsetInLine));
            dataForRdResp.enq(tuple7(addr, hitMiss, boundsOffset2, boundsVirtBase, bidx, fidx, boundsLength));
        end
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr;
        pfQueue.deq;
        return tuple3({pfQueue.first, '0}, almightyCap, ?);
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        let evt = EventsPrefetcher {
            evt_0: perf_events[0].evt_0,
            evt_1: perf_events[0].evt_1,
            evt_2: perf_events[0].evt_2,
            evt_3: perf_events[0].evt_3,
            evt_4: perf_events[0].evt_4
        };
        return evt;
    endmethod
`endif

endmodule

module mkCapBitmapPrefetcher#(Parameter#(maxCapSizeToTrack) _, Parameter#(bitmapTableSize) __, 
        Parameter#(filterTableSize) ___, Parameter#(inverseDecayChance) ____)(CheriPCPrefetcher) provisos (
    Add#(a__, TLog#(TDiv#(maxCapSizeToTrack, 64)), 58),
    NumAlias#(pageIndexBits, 6), //assume 4k pages
    Alias#(pageAddressT, Bit#(TSub#(LineAddrSz, pageIndexBits))),
    NumAlias#(tagBits, 16),
    NumAlias#(pfQueueSize, 16),
    NumAlias#(linesInPage, 64),
    NumAlias#(bitmapLength, 64),
    Alias#(bitmapIndexT, Bit#(TLog#(bitmapLength))),
    Alias#(bitmapTableIdxT, Bit#(TLog#(bitmapTableSize))),
    Alias#(filterTableIdxT, Bit#(TLog#(filterTableSize))),
    Alias#(filterTableIdxTagT, Bit#(TAdd#(TLog#(filterTableSize), tagBits))),
    Alias#(bitmapEntryT, BitmapEntry#(bitmapLength)),
    Alias#(filterEntryT, FilterEntry#(tagBits)),
    Alias#(pageBitmapT, Vector#(64, LineState)),

    Add#(1, b__, TDiv#(64, TAdd#(TLog#(filterTableSize), 16))),
    Add#(c__, 64, TMul#(TDiv#(64, TAdd#(TLog#(filterTableSize), 16)), TAdd#(TLog#(filterTableSize), 16))),
    Add#(d__, 52, TMul#(TDiv#(52, TAdd#(TLog#(filterTableSize), 16)), TAdd#(TLog#(filterTableSize), 16))),
    Add#(1, f__, TDiv#(64, TLog#(bitmapTableSize))),
    Add#(g__, 64, TMul#(TDiv#(64, TLog#(bitmapTableSize)),TLog#(bitmapTableSize))), 
    Add#(1, e__, TDiv#(52, TAdd#(TLog#(filterTableSize), 16))),
    Add#(h__, 16, TMul#(TDiv#(16, TLog#(bitmapTableSize)), TLog#(bitmapTableSize))),
    Add#(1, i__, TDiv#(16, TLog#(bitmapTableSize))),
    Add#(j__, 2, TLog#(bitmapTableSize)),
    Add#(k__, 1, TLog#(bitmapTableSize)),
    Add#(l__, 8, TLog#(bitmapTableSize)),
    Add#(n__, 64, TMul#(TDiv#(64, TSub#(TLog#(bitmapTableSize), 1)),
    TSub#(TLog#(bitmapTableSize), 1))),
    Add#(1, m__, TDiv#(64, TSub#(TLog#(bitmapTableSize), 1))),
    Add#(3, o__, TLog#(bitmapTableSize))

);
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (4, unpack (0));
    RWBramCoreSequential#(TLog#(bitmapTableSize), bitmapEntryT, 2) bt <- mkRWBramCoreSequential();
    RWBramCore#(filterTableIdxT, filterEntryT) ft <- mkRWBramCoreForwarded();
    Fifo#(pfQueueSize, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) pfQueue <- mkOverflowPipelineFifo;
    Fifo#(1, Tuple8#(Addr, HitOrMiss, LineAddr, Bool, Bool, bitmapTableIdxT, filterTableIdxTagT, Addr)) dataForRdResp <- mkPipelineFifo;
    Fifo#(1, Tuple3#(Bit#(7), Addr, Addr)) dataForRdResp2 <- mkPipelineFifo;
    Fifo#(4, Tuple6#(Vector#(linesInPage, Bool), pageAddressT, UInt#(8), Addr, Addr, Addr)) issuePrefetchesQueue <- mkBypassFifo;
    Reg#(Tuple5#(pageAddressT, UInt#(8), Addr, Addr, Addr)) dataForIssuePrefetches <- mkConfigReg(?);
    Reg#(Vector#(linesInPage, Bool)) canPrefetch <- mkConfigReg(replicate(False));
    Reg#(Bit#(12)) randomCounter <- mkConfigReg(0);

    function LineState upgrade(LineState st) = 
        case (st)
            NOTUSED: USED1;
            USED1: USED2;
            USED2: USED3;
            USED3: USED3;
        endcase;

    function LineState downgrade(LineState st) =
        case (st)
            NOTUSED: NOTUSED;
            USED1: NOTUSED;
            USED2: USED1;
            USED3: USED2;
        endcase;

    rule incrRandomCounter;
        if (randomCounter == fromInteger(valueof(inverseDecayChance))-1)
            randomCounter <= 0;
        else
            randomCounter <= randomCounter + 1;
    endrule

    rule processRdResp;
        
        Vector#(128, LineState) bitmap = append(bt.rdResp[0].bitmap, bt.rdResp[1].bitmap);
        //if (`VERBOSE) $display("%t prefetcher:processRdResp bitmap: ", $time, fshow(bitmap));
        bt.deqRdResp;
        filterEntryT fte = ft.rdResp;
        ft.deqRdResp;
        let {accessAddr, hitMiss, boundsOffset2, ignoreFirstPage, ignoreSecondPage, btIdx, ftIdxTag, boundsLength} = dataForRdResp.first;
        let {accessIdx, pageStartBoundsOffset, boundsVirtBase} = dataForRdResp2.first;
        LineAddr accessLineAddr = truncateLSB(accessAddr);
        dataForRdResp.deq;
        dataForRdResp2.deq;

        Bit#(tagBits) ftTag = truncateLSB(ftIdxTag);

        pageAddressT pa = truncateLSB(accessAddr);
        LineAddr pageStartAddr = {pa, '0};
        Bit#(6) accessLineInPage = accessAddr[11:6];
        Bit#(7) accessLineInPage2 = extend(accessLineInPage);
        Bit#(7) pageStartBitmapIdx = accessIdx - accessLineInPage2;
        doAssert(pageStartBitmapIdx < 64, "Page start should always be in first half of bitmap");
        Bit#(7) pageEndBitmapIdx = pageStartBitmapIdx + 64;
        Bool accessInFirstBitmapGroup = (accessIdx < 64);
        if (hitMiss == MISS && (ftTag != fte.tag || fte.prefetched == False)) begin
            
            //Update filter table
            fte.tag = ftTag;
            fte.prefetched = True;
            ft.wrReq(truncate(ftIdxTag), fte); 

            //Find cache lines in current page to possibly prefetch
            Vector#(linesInPage, Bool) canPrefetchVec = replicate(False);
            Vector#(linesInPage, Bool) atLeastUsed2 = replicate(False);
            if (`VERBOSE) $display("%t prefetcher:processRdResp accesslineinpage: %d pagestartbitmapidx %d pageendbitmapidx %d accessix %d",
                 $time, accessLineInPage, pageStartBitmapIdx, pageEndBitmapIdx, accessIdx);
                 
            for (Integer i = 0; i < valueOf(linesInPage); i = i + 1) begin
                Bit#(8) idx = fromInteger(i)+extend(pageStartBitmapIdx); 
                if ((!ignoreFirstPage || idx >= 64) &&
                    (!ignoreSecondPage || idx < 64) &&
                    idx < 128 &&
                    fromInteger(i) != (accessLineAddr - pageStartAddr)) begin
                    //fromInteger(i) + pageStartCapOffset >= 0 && fromInteger(i) + pageStartCapOffset < fromInteger(valueof(bitmapLength))) begin
                    LineState st = bitmap[fromInteger(i)+pageStartBitmapIdx];
                    canPrefetchVec[i] = st == USED3 || st == USED2;
                    atLeastUsed2[i] = st == USED1 || st == USED2 || st == USED3;
                end
            end
            
            //if (`VERBOSE) $display("%t prefetcher:processRdResp canPrefetchVec: ", 
                //$time, fshow(canPrefetchVec));
            issuePrefetchesQueue.enq(tuple6(canPrefetchVec, pa, unpack(truncate(accessLineAddr - pageStartAddr)), pageStartBoundsOffset, boundsLength, boundsVirtBase));

            if (`VERBOSE) $display("%t prefetcher:processRdResp MISS offset %h in new cap %h (for cap idx %h), found %d possible prefetches!", 
                $time, boundsOffset2, ftIdxTag, btIdx, countElem(True, canPrefetchVec));
            
            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = 1;
            evt.evt_2 = (boundsLength <= 131072) ? 0 : extend(pack(countElem(True, canPrefetchVec)));
            evt.evt_1 = extend(pack(countElem(True, canPrefetchVec)));
            //evt.evt_2 = extend(pack(countElem(True, canPrefetchVec)));
            perf_events[1] <= evt;
            
            
            
        end
        
        //NB: Change this for LLC prefetching -- then L1 acts as filter, so can upgrade and downgrade on hits too!
        //For L1, will get many hits for the same cache line, so only want to do stuff for misses.
        if (hitMiss == MISS) begin
            
            Vector#(64, LineState) writeBackBitmap; // = takeAt(accessInFirstBitmapGroup ? 0 : 64, bitmap);
            if (accessInFirstBitmapGroup) begin
                writeBackBitmap = take(bitmap);
            end
            else begin
                writeBackBitmap = drop(bitmap);
            end
            //Downgrade all states with probability 1/inverseDecayChance
            if (randomCounter == 0) begin
            
                for (Integer i = 0; i < 64; i = i + 1) begin
                    writeBackBitmap[i] = downgrade(writeBackBitmap[i]);
                end
                if (`VERBOSE) $display("%t prefetcher:processRdResp downgrading lines in cap %h!. Status now: ", 
                $time, btIdx);
                for (Integer i = 0; i < 64; i = i + 1) begin
                    if (`VERBOSE) $write(" ", fshow(writeBackBitmap[i]));
                end
                
            end
            //Update state of cache line in bitmap
            //LineAddr accessLineAddr = truncateLSB(addr);
            EventsPrefetcher evt = unpack(0);
            evt.evt_3 = 1;
            perf_events[2] <= evt;
            Bit#(6) accessIdx2 = truncate(accessIdx);
            LineState state = writeBackBitmap[accessIdx2];
            LineState nextState = upgrade(state);
            writeBackBitmap[accessIdx2] = nextState;
            
            if (`VERBOSE) $display("%t prefetcher:processRdResp upgrading offset %h in cap %h to ", $time, boundsOffset2, btIdx, fshow(nextState));
            bt.wrReq(btIdx, unpack(pack(writeBackBitmap)));
            
        end
        
    endrule

    rule issuePrefetchesQToReg;
        if (canPrefetch == replicate(False) || !issuePrefetchesQueue.notFull) begin
            issuePrefetchesQueue.deq;
            let {canPrefetchVec, pa, accessOffset, pageStartBoundsOffset, boundsLength, boundsVirtBase} = issuePrefetchesQueue.first;
            canPrefetch <= canPrefetchVec;
            dataForIssuePrefetches <= tuple5(pa, accessOffset, pageStartBoundsOffset, boundsLength, boundsVirtBase);
        end
    endrule

    rule issuePrefetches;
        let {pageStartAddr, accessOffset, pageStartBoundsOffset, boundsLength, boundsVirtBase} = dataForIssuePrefetches;
        Vector#(linesInPage, Bool) canPrefetchAbove = replicate(False);
        Vector#(linesInPage, Bool) canPrefetchBelow = replicate(False);
        for (Integer i = 1; i < valueof(linesInPage); i = i + 1) begin
            if (fromInteger(i)+accessOffset < fromInteger(valueof(linesInPage)))
                canPrefetchAbove[i] = canPrefetch[fromInteger(i)+accessOffset];
        end
        for (Integer i = 1; i < valueof(linesInPage); i = i + 1) begin
            //Check for underflow
            if (accessOffset - fromInteger(i) < fromInteger(valueOf(linesInPage)))
                canPrefetchBelow[i] = canPrefetch[accessOffset - fromInteger(i)];
        end

        let canPrefetchAboveIdx = findElem(True, canPrefetchAbove);
        let canPrefetchBelowIdx = findElem(True, canPrefetchBelow);
        Maybe#(UInt#(6)) prefetchIdx = Invalid;
        if (canPrefetchAboveIdx matches tagged Valid .aboveIdx) begin
            if (canPrefetchBelowIdx matches tagged Valid .belowIdx) begin
                //Prefetch the closest cache lines first
                if (aboveIdx <= belowIdx) 
                    prefetchIdx = tagged Valid (truncate(accessOffset)+aboveIdx);
                else 
                    prefetchIdx = tagged Valid (truncate(accessOffset)-belowIdx);
            end
            else begin
                prefetchIdx = tagged Valid (truncate(accessOffset)+aboveIdx);
            end
        end
        else if (canPrefetchBelowIdx matches tagged Valid .belowIdx) begin
            prefetchIdx = tagged Valid (truncate(accessOffset)-belowIdx);
        end
        
        if (prefetchIdx matches tagged Valid .idx) begin
            //if (`VERBOSE) $display("%t prefetcher:issuePrefetches canPrefetch at start: ", $time, fshow(canPrefetch));
            let canPrefetchVec = canPrefetch;
            canPrefetchVec[idx] = False;
            canPrefetch <= canPrefetchVec;
            LineAddr toPrefetch = {pageStartAddr, '0} + pack(extend(idx));
            Addr toPrefetchAddr = Addr'{toPrefetch, '0};
            CapPipe cp = almightyCap;
            Addr prefetchOffset = pageStartBoundsOffset + pack(extend(idx)*64);
            let cp1 = setAddr(cp, boundsVirtBase);
            let cp2 = setBounds(cp1.value, boundsLength);
            let cp3 = setOffset(cp2.value, prefetchOffset);

            pfQueue.enq(tuple3(toPrefetchAddr, cp3.value, ?));
            if (`VERBOSE) $display("%t -- prefetcher:issuePrefetches %h prefetchOffset %h pageStartOffset %h boundsLength %h cap: ", 
                $time, toPrefetchAddr, prefetchOffset, pageStartBoundsOffset, boundsLength, fshow(cp3.value));

            EventsPrefetcher evt = unpack(0);
            evt.evt_4 = 1;
            perf_events[3] <= evt;
        end
        
    endrule

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset1, Addr boundsLength1, Addr boundsVirtBase1, Bit#(31) capPerms);
        if (boundsLength1 > 64 && boundsLength1 <= fromInteger(valueOf(maxCapSizeToTrack))) begin
            /*
            //Measure bounds alignment
            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = 1;
            evt.evt_2 = (boundsVirtBase[5:0] == 0) ? 1 : 0;
            evt.evt_1 = (boundsVirtBase[3:0] == 0) ? 1 : 0;
            //evt.evt_2 = extend(pack(countElem(True, canPrefetchVec)));
            perf_events[1] <= evt;
            */

            //$display("%t prefetcher:reportAccess %h with bounds length %d base %h offset %d", $time, addr, boundsLength, boundsVirtBase, boundsOffset);
            //Not all objects are aligned in the same way, so we separate the training bitmaps for objects that are aligned differently
            //Otherwise, one 8-byte field in different objects might land in 2 different cache lines, 
            //meaning both cache lines would be prefetched every time.
            //As this reduces the amount of training data, this is done partially, grouping objects with same 16byte alignment together

            pageAddressT pa = truncateLSB(addr);
            Bit#(6) accessLineInPage = addr[11:6];
            /*
            //replacing bounds with non cheri info. pretend each page is a cap
            Addr boundsOffset = extend(addr[11:0]);
            Addr boundsLength = 4096;
            Addr boundsVirtBase = {pa, '0};
            */
            Addr boundsOffset = boundsOffset1;
            Addr boundsLength = boundsLength1;
            Addr boundsVirtBase = boundsVirtBase1;

            Bit#(2) capStart16byteOffset = boundsVirtBase[5:4]; 
            Bit#(6) offsetInLine = truncate(boundsVirtBase);
            Addr pageStartBoundsOffset = boundsOffset - extend(addr[11:0]);
            //boundsOffset2 tracks the idx of the cache line in the capability.
            LineAddr boundsOffset2 = truncateLSB(boundsOffset+extend(offsetInLine));
            Bit#(8) cacheLineGroup = truncate(boundsOffset2 >> 6);
            //boundsOffset2pagestart tracks the idx of the cache line in the capability of page start.
            LineAddr boundsOffset2PageStart = boundsOffset2 - extend(accessLineInPage);
            Bit#(8) cacheLineGroupPageStart = truncate(boundsOffset2PageStart >> 6);
            Bit#(8) numLineGroupsInCap = truncate((boundsLength + 4095) >> 12);
            //Check which bitmap half will the access be in
            Bit#(7) accessIdxInBitmap = {1'b0, boundsOffset2[5:0]} + ((cacheLineGroup == cacheLineGroupPageStart) ? 0 : 64);
            Bool ignoreFirstPage = (cacheLineGroupPageStart == -1); //page starts before cap starts
            Bool ignoreSecondPage = (cacheLineGroupPageStart == numLineGroupsInCap-1); //Page starts in last line group of cap
            Bit#(TSub#(TLog#(bitmapTableSize), 1)) ogHash = (hash(boundsLength) /*^ hash(boundsVirtBase)*/ ^ extend(capStart16byteOffset));
            bitmapTableIdxT bidx =       {ogHash, 1'b0} + signExtend(cacheLineGroupPageStart);
            bitmapTableIdxT write_bidx = {ogHash, 1'b0} + signExtend(cacheLineGroup);
            doAssert(bidx == write_bidx || bidx + 1 == write_bidx, "");
            bt.rdReq(bidx);
            filterTableIdxTagT fidx = hash(boundsVirtBase) ^ hash(pa);
            ft.rdReq(truncate(fidx));
            $display("%t -- prefetcher:reportAccess %h boundslength %d boundsoffset2 %h ignorefirstp %d ignroesecondp %d readbidx %h write_bidx %h accessidxbitmap %d oghash %h clinegroup %d clinepagest %d",
             $time, addr, boundsLength, boundsOffset2, ignoreFirstPage, ignoreSecondPage, bidx, write_bidx, accessIdxInBitmap, ogHash, cacheLineGroup, cacheLineGroupPageStart);
            dataForRdResp.enq(tuple8(addr, hitMiss, boundsOffset2, ignoreFirstPage, ignoreSecondPage, write_bidx, fidx, boundsLength));
            dataForRdResp2.enq(tuple3(accessIdxInBitmap, pageStartBoundsOffset, boundsVirtBase));
        end
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr if (randomCounter[0:0] == 1'b0);
        $display ("%t prefetcher:getNextPrefetchAddr ", $time, fshow(pfQueue.first));
        pfQueue.deq;
        return pfQueue.first;
    endmethod
    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
        $display ("prefetcher:reportCacheDataArrival line ", fshow(lineWithTags), " addr %x wasMiss %d wasPrefetch %d boundsOffset %h boundsLength %d boundsVirtBase %x", 
            addr, wasMiss, wasPrefetch, boundsOffset, boundsLength, boundsVirtBase);
    endmethod
    
    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        let evt = EventsPrefetcher {
            evt_0: perf_events[0].evt_0,
            evt_1: perf_events[0].evt_1,
            evt_2: perf_events[0].evt_2,
            evt_3: perf_events[0].evt_3,
            evt_4: perf_events[0].evt_4
        };
        return evt;
    endmethod
`endif

endmodule

//Indexed by hash of bounds length and offset
typedef struct {
    Bit#(tagBits) tag;
    LineState state;
    Bit#(24) lastUsedOffset;
} PtrTableEntry #(numeric type tagBits) deriving (Bits, Eq, FShow);

//Indexed by virtual address
typedef struct {
    Bit#(tagBits) tag;
    Bit#(ptrTableIdxTagBits) ptrTableIdxTag;
} TrainingTableEntry#(numeric type tagBits, numeric type ptrTableIdxTagBits) deriving (Bits, Eq, FShow);

module mkCapPtrPrefetcher#(DTlbToPrefetcher toTlb, Parameter#(ptrTableSize) _, Parameter#(trainingTableSize) __, Parameter#(inverseDecayChance) ___)(CheriPCPrefetcher) provisos (
    NumAlias#(ptrTableTagBits, 16),
    NumAlias#(trainingTableTagBits, 16),
    NumAlias#(ptrTableIdxBits, TLog#(ptrTableSize)),
    NumAlias#(ptrTableIdxTagBits, TAdd#(ptrTableIdxBits, ptrTableTagBits)),
    NumAlias#(trainingTableIdxBits, TLog#(trainingTableSize)),
    NumAlias#(trainingTableIdxTagBits, TAdd#(trainingTableIdxBits, trainingTableTagBits)),
    Alias#(ptrTableIdxT, Bit#(ptrTableIdxBits)),
    Alias#(ptrTableIdxTagT, Bit#(ptrTableIdxTagBits)),
    Alias#(ptrTableTagT, Bit#(ptrTableTagBits)),
    Alias#(ptrTableEntryT, PtrTableEntry#(ptrTableTagBits)),
    Alias#(trainingTableIdxT, Bit#(trainingTableIdxBits)),
    Alias#(trainingTableIdxTagT, Bit#(trainingTableIdxTagBits)),
    Alias#(trainingTableTagT, Bit#(trainingTableTagBits)),
    Alias#(trainingTableEntryT, TrainingTableEntry#(trainingTableTagBits, ptrTableIdxTagBits)),
    Alias#(potentialPrefetchT, Tuple3#(ptrTableIdxTagT, CapPipe, Bool)),

    Add#(a__, 60, TMul#(TDiv#(60, TAdd#(TLog#(ptrTableSize), 16)), TAdd#(TLog#(ptrTableSize), 16))),
    Add#(1, b__, TDiv#(64, TAdd#(TLog#(ptrTableSize), 16))),
    Add#(c__, TAdd#(TLog#(trainingTableSize), 16), 64),
    Add#(1, d__, TDiv#(58, TAdd#(TLog#(trainingTableSize), 16))),
    Add#(1, l__, TDiv#(64, TAdd#(TLog#(trainingTableSize), 16))),
    Add#(k__, 64, TMul#(TDiv#(64, TAdd#(TLog#(trainingTableSize), 16)), TAdd#(TLog#(trainingTableSize), 16))),
    Add#(e__, 58, TMul#(TDiv#(58, TAdd#(TLog#(trainingTableSize), 16)), TAdd#(TLog#(trainingTableSize), 16))),
    Add#(g__, 64, TMul#(TDiv#(64, TAdd#(14, TLog#(ptrTableSize))), TAdd#(14, TLog#(ptrTableSize)))),
    Add#(i__, 58, TMul#(TDiv#(58, TAdd#(14, TLog#(ptrTableSize))), TAdd#(14, TLog#(ptrTableSize)))),
    Add#(1, f__, TDiv#(58, TAdd#(14, TLog#(ptrTableSize)))),
    Add#(1, j__, TDiv#(64, TAdd#(14, TLog#(ptrTableSize)))),
    Add#(h__, 2, TLog#(ptrTableSize)),
    Add#(TLog#(ptrTableSize), m__, 48),
    Add#(p__, TLog#(ptrTableSize), 60),
    Add#(1, n__, TDiv#(64, TLog#(ptrTableSize))),
    Add#(o__, 64, TMul#(TDiv#(64, TLog#(ptrTableSize)), TLog#(ptrTableSize))),
    Add#(q__, TAdd#(TLog#(ptrTableSize), 16), 60)
);
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (5, unpack (0));
    RWBramCoreSequential#(ptrTableIdxBits, ptrTableEntryT, 4) pt <- mkRWBramCoreSequential();
    RWBramCore#(trainingTableIdxT, trainingTableEntryT) tt <- mkRWBramCore();
    Fifo#(1, Tuple2#(trainingTableIdxTagT, Bit#(24))) dataForTtRead <- mkPipelineFifo;
    Fifo#(4, trainingTableIdxT) wipeTtEntry <- mkOverflowBypassFifo;
    Fifo#(4, Tuple2#(trainingTableIdxT, trainingTableEntryT)) installTtEntry <- mkOverflowBypassFifo;
    Fifo#(8, Tuple2#(ptrTableIdxTagT, Bit#(24))) ptUpgradeQueue <- mkOverflowBypassFifo;
    Fifo#(1, Tuple2#(ptrTableIdxTagT, Bit#(24))) ptUpgradeQueueReading <- mkPipelineFifo;

    Fifo#(8, Vector#(4, potentialPrefetchT)) ptLookupQueue <- mkOverflowBypassFifo;
    Fifo#(1, Vector#(4, potentialPrefetchT)) ptLookupQueueReading <- mkPipelineFifo;
    Reg#(Vector#(4, Bool)) ptLookupUsedEntry <- mkReg(replicate(False));

    Fifo#(8, CapPipe) tlbLookupQueue <- mkOverflowPipelineFifo;
    Fifo#(8, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) prefetchQueue <- mkOverflowBypassFifo;
    Reg#(Bit#(8)) randomCounter <- mkConfigReg(0);
    Reg#(LineAddr) lastLookupLineAddr <- mkReg(0);
    Reg#(trainingTableIdxTagT) lastMatchedTit <- mkReg(0);

    
    function ptrTableIdxTagT getIdxTag(Addr boundsLength, Addr boundsOffset, Addr boundsVirtBase);
        //boundsOffset should be an offset of a cap, so 16 byte aligned, so drop its lowest 4 bits
        //but also, need lowest 2 bits to be sequential and determined by boundsOffset
         //{hash(boundsLength) ^ hash(boundsOffset[63:6]), boundsOffset[5:4]};
        ptrTableIdxT lenHash = hash(boundsLength) ^ hash(boundsVirtBase);
        return truncate(extend(lenHash) + boundsOffset[63:4]);
    endfunction

    function trainingTableIdxTagT getTrainingIdxTag(Addr vaddr, Addr boundsVirtBase, Addr boundsLength) =
        hash(boundsVirtBase ^ boundsLength);
        //hash(getLineAddr(vaddr));

    function LineState upgrade(LineState st) = 
        case (st)
            NOTUSED: USED1;
            USED1: USED2;
            USED2: USED3;
            USED3: USED3;
        endcase;

    function LineState downgrade(LineState st) =
        case (st)
            NOTUSED: NOTUSED;
            USED1: NOTUSED;
            USED2: USED1;
            USED3: USED2;
        endcase;

    rule incrRandomCounter;
        if (randomCounter == fromInteger(valueof(inverseDecayChance))-1)
            randomCounter <= 0;
        else
            randomCounter <= randomCounter + 1;
    endrule

    rule doInstallTtEntry;
        let {tIdx, te} = installTtEntry.first;
        installTtEntry.deq;
        tt.wrReq(tIdx, te);
    endrule
    
    (* descending_urgency = "doInstallTtEntry, doWipeTtEntry" *)
    rule doWipeTtEntry;
        let tIdx = wipeTtEntry.first;
        wipeTtEntry.deq;
        trainingTableEntryT te = unpack(0);
        tt.wrReq(tIdx, te);
    endrule

    rule processTtRead;
        dataForTtRead.deq;
        let {tit, boundsOffset} = dataForTtRead.first;
        trainingTableTagT tTag = truncateLSB(tit);
        trainingTableIdxT tIdx = truncate(tit);
        tt.deqRdResp;
        let te = tt.rdResp;
        if (te.tag == tTag && lastMatchedTit != tit) begin
            //Match -- upgrade ptrTable
            if (`VERBOSE) $display("%t Prefetcher training table match! Will upgrade ptr table pit %h", $time, te.ptrTableIdxTag);
            ptUpgradeQueue.enq(tuple2(te.ptrTableIdxTag, boundsOffset));
            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = 1;
            perf_events[0] <= evt;
            wipeTtEntry.enq(tIdx);
            lastMatchedTit <= tit;
        end
        else begin
            if (`VERBOSE) $display("%t Prefetcher training table mismatch! table %h now %h", $time, te.tag, tTag);
        end
    endrule

    rule doPtReadForUpgrade;
        if (`VERBOSE) $display("%t Prefetcher doPtReadForUpgrade", $time);
        let {pit, boundsOffset} = ptUpgradeQueue.first;
        ptUpgradeQueue.deq;
        ptUpgradeQueueReading.enq(tuple2(pit, boundsOffset));
        pt.rdReq(truncate(pit));
    endrule

    rule processPtReadUpgrade;
        let pteVec = pt.rdResp;
        let pte = pteVec[0];
        pt.deqRdResp;
        let {pit, boundsOffset} = ptUpgradeQueueReading.first;
        ptUpgradeQueueReading.deq;
        if (pte.tag == truncateLSB(pit)) begin
            pte.state = upgrade(pte.state);
            pte.lastUsedOffset = boundsOffset;
            if (`VERBOSE) $display("%t Prefetcher processPtReadUpgrade pit %h set lastUsedOffset to %d, upgrading to ", $time, pit, boundsOffset, fshow(pte.state));
            /*
            EventsPrefetcher evt = unpack(0);
            evt.evt_1 = 1;
            perf_events[1] <= evt;
            */
        end
        else begin
            pte.state = USED1;
            pte.tag = truncateLSB(pit);
            pte.lastUsedOffset = boundsOffset;
            if (`VERBOSE) $display("%t Prefetcher processPtReadUpgrade tag mismatch set lastUsedOffset %d reset pit %h entry to ", $time, boundsOffset, pit, fshow(pte.state));
        end
        pt.wrReq(truncate(pit), pte);
    endrule

    (* descending_urgency = "doPtReadForUpgrade, doPtReadForLookup" *)
    rule doPtReadForLookup;
        $display("%t doPtReadForLookup", $time);
        let pitVec = ptLookupQueue.first;
        ptLookupQueue.deq;
        ptLookupQueueReading.enq(pitVec);
        pt.rdReq(truncate(tpl_1(pitVec[0])));

        /*
        EventsPrefetcher evt = unpack(0);
        evt.evt_2 = 1;
        perf_events[2] <= evt;
        */
    endrule

    //usedPrefetch, entry from pt, pit, capValid
    function Bool canPrefetch(Tuple4#(Bool, ptrTableEntryT, ptrTableIdxTagT, Bool) pte) = 
        !tpl_1(pte) && 
        tpl_4(pte) &&
        tpl_2(pte).tag == truncateLSB(tpl_3(pte)) && 
        (tpl_2(pte).state == USED2 || tpl_2(pte).state == USED3);


    function Bool canDoAnyPrefetch;
        let pteVec = pt.rdResp;
        let ppVec = ptLookupQueueReading.first;
        return any(canPrefetch, zip4(ptLookupUsedEntry, pteVec, map(tpl_1, ppVec), map(tpl_3, ppVec)));
    endfunction

    rule deqPtRdResp if (!canDoAnyPrefetch);
        $display("%t deqPtRdResp", $time, fshow(ptLookupQueueReading.first), fshow(pt.rdResp), fshow (ptLookupUsedEntry));
        pt.deqRdResp;
        ptLookupQueueReading.deq;
        ptLookupUsedEntry <= replicate(False);
    endrule

    (* descending_urgency = "deqPtRdResp, processPtReadForLookup" *)
    rule processPtReadForLookup;
        //downgrade pte with some chance
        let ppVec = ptLookupQueueReading.first;
        let pteVec = pt.rdResp;
        if (`VERBOSE) $display("%t Prefetcher processPtReadForLookup ", $time, fshow(ptLookupUsedEntry), fshow(pteVec));
        let prefetchIdx = findIndex(canPrefetch, zip4(ptLookupUsedEntry, pteVec, map(tpl_1, ppVec), map(tpl_3, ppVec)));
        if (prefetchIdx matches tagged Valid .idx) begin
            let pte = pteVec[idx];
            let pit = tpl_1(ppVec[idx]);
            Addr offset = extend(pte.lastUsedOffset);
            //Addr offset = 0;
            let cap = setOffset(tpl_2(ppVec[idx]), offset).value;
            if (`VERBOSE) $display("%t Prefetcher processPtReadForLookup canprefetch pit %h table tag %h read tag %h target vaddr %h offset %h", $time, pit, pte.tag, ptrTableTagT'{truncateLSB(pit)}, getAddr(cap), offset);
            tlbLookupQueue.enq(cap);
            ptLookupUsedEntry[idx] <= True;
            if (randomCounter == 0) begin
                pte.state = downgrade(pte.state);
                pt.wrReq(truncate(pit), pte);
                if (`VERBOSE) $display("%t Prefetcher processPtReadForLookup %h downgrading to ", $time, pit, fshow(pte.state));
            end
            EventsPrefetcher evt = unpack(0);
            evt.evt_1 = 1;
            /*
            if (offset <= 64) begin
                evt.evt_2 = 1;
            end
            */
            perf_events[2] <= evt;
        end
    endrule
        
    rule doTlbLookup;
        let cap = tlbLookupQueue.first;
        tlbLookupQueue.deq;
        toTlb.prefetcherReq(cap, Invalid);
    endrule

    rule getTlbResp;
        let resp = toTlb.prefetcherResp;
        toTlb.deqPrefetcherResp;
        if (`VERBOSE) $display("%t Prefetcher got TLB response: ", $time, fshow(resp));
        if (!resp.haveException && resp.paddr != 0) begin
            prefetchQueue.enq(tuple3(resp.paddr, resp.cap, ?));
            // EventsPrefetcher evt = unpack(0);
            // evt.evt_3 = 1;
            // perf_events[3] <= evt;
        end
    endrule
    

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        //Lookup addr in training table, if get a hit, update ptrTable
        if (boundsLength <= 131072*16) begin
            Addr vaddr = boundsVirtBase + boundsOffset;
            trainingTableIdxTagT tit = getTrainingIdxTag(vaddr, boundsVirtBase, boundsLength);
            Bit#(24) usedOffset = truncate(boundsOffset);
            if (`VERBOSE) $display("%t Prefetcher reportAccess %h offset %h boundslen %d lineoffset %d tit %h", $time, addr, boundsOffset, boundsLength, usedOffset, tit, fshow(hitMiss));
            dataForTtRead.enq(tuple2(tit, usedOffset));
            tt.rdReq(truncate(tit));
        end
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
        if (boundsLength <= 131072*16) begin
            $display ("%t Prefetcher reportCacheDataArrival wasMiss %d wasPrefetch %d ", $time, wasMiss, wasPrefetch, fshow(lineWithTags));

            //Add accessed cap to training table in case we dereference it later.
            if (addr[3:0] == 0) begin
                //addr targeted a multiple of 16 bytes -- so potentially a capability
                let offset = getLineMemDataOffset(addr);
                MemTaggedData d = getTaggedDataAt(lineWithTags, offset);
                CapPipe cap = fromMem(unpack(pack(d)));
                if (d.tag && boundsVirtBase != getBase(cap)) begin
                    //install ptr addr of cap in training table
                    ptrTableIdxTagT pit = getIdxTag(boundsLength, boundsOffset, boundsVirtBase);
                    trainingTableIdxTagT tit = getTrainingIdxTag(getAddr(cap), saturating_truncate(getBase(cap)), saturating_truncate(getLength(cap)));
                    trainingTableTagT tTag = truncateLSB(tit);
                    trainingTableIdxT tIdx = truncate(tit);
                    trainingTableEntryT te;
                    if (`VERBOSE) $display("%t Prefetcher reportDataArrival adding training table entry! access addr %h boundslen %d offset %h prefetch %b ptraddress %h tit %h pit %h", 
                        $time, addr, boundsLength, boundsOffset, wasPrefetch, getAddr(cap), tit, pit);
                    te.tag = tTag;
                    te.ptrTableIdxTag = pit;
                    installTtEntry.enq(tuple2(tIdx, te));
                    tt.wrReq(tIdx, te);

                    EventsPrefetcher evt = unpack(0);
                    evt.evt_4 = 1;
                    if (boundsVirtBase != getBase(cap)) begin
                        //evt.evt_2 = 1;
                    end
                    perf_events[4] <= evt;
                end
            end

            //Previous condition was wasMiss && !wasPrefetch
            if (wasMiss) begin
                //TODO prevent runaway prefetching
                //Queue caps here for lookup in ptr table
                //Only do so on a cache miss to prevent too many prefetches
                Vector#(4, potentialPrefetchT) v;
                Bool foundOneCap = False;
                Addr clineStartOffset = (boundsOffset-extend(addr[5:0]));
                for (Integer i = 0; i < 4; i = i + 1) begin
                    MemTaggedData d = getTaggedDataAt(lineWithTags, fromInteger(i));
                    CapPipe cap = fromMem(unpack(pack(d)));
                    ptrTableIdxTagT pit = getIdxTag(boundsLength, clineStartOffset+fromInteger(i)*16, boundsVirtBase);
                    v[i] = tuple3(pit, cap, d.tag);
                    foundOneCap = foundOneCap || d.tag;
                end
                if (foundOneCap) begin
                    if (`VERBOSE) $display("%t Prefetcher reportDataArrival addr %h prefetech %b adding %d caps for prefetch lookups (clinestartoffset %h)", 
                        $time, addr, wasPrefetch, countElem(True, map(tpl_3, v)), clineStartOffset, fshow(v));
                    ptLookupQueue.enq(v);
                    EventsPrefetcher evt = unpack(0);
                    evt.evt_3 = 1;
                    if (wasPrefetch) begin
                        evt.evt_2 = 1;
                    end
                    perf_events[3] <= evt;
                    lastLookupLineAddr <= getLineAddr(addr);
                end
            end
        end
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, tpl_1(prefetchQueue.first));
        prefetchQueue.deq;
        return prefetchQueue.first;
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return perf_events[0];
    endmethod
`endif

endmodule

module mkCapPtrTestPrefetcher(CheriPCPrefetcher) provisos ();
    Fifo#(4, Addr) prefetchRq <- mkOverflowPipelineFifo;
    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        if (`VERBOSE) $display("%t Prefetcher reportAccess %h boundslen %d", $time, addr, boundsLength, fshow(hitMiss));
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
        MemTaggedData d = getTaggedDataAt(lineWithTags, 0);
        CapPipe cap = fromMem(unpack(pack(d)));
        if (d.tag) begin
            prefetchRq.enq(getAddr(cap));
            if (`VERBOSE) $display("%t Prefetcher reportDataArrival CapPipe ", $time, fshow(cap));
        end
        if (`VERBOSE) $display("%t Prefetcher reportDataArrival %h boundslen %d prefetch %b", $time, addr, boundsLength, wasPrefetch, fshow(lineWithTags));
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, prefetchRq.first);
        prefetchRq.deq;
        return tuple3(prefetchRq.first, almightyCap, ?);
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return  unpack(0);
    endmethod
`endif

endmodule

typedef struct {
    tagT tag; 
    Bit#(8) numLoads;
    Bit#(16) lastBoundsLenHash;
    Bit#(16) lastBoundsBaseHash;
    Bool diffLenCounted;
    Bool diffBaseCounted;
    Bool lruMostRecent;
} MeasurmentTableEntry#(type tagT) deriving (Bits, Eq, FShow);

module mkPCCapMeasurer(CheriPCPrefetcher) provisos (
    NumAlias#(mtEntries, 4096),
    Alias#(mtIdxT, Bit#(TLog#(mtEntries))),
    Alias#(mtTagT, Bit#(20)),
    Alias#(mtEntryT, MeasurmentTableEntry#(mtTagT))
);
    RWBramCore#(mtIdxT, Vector#(2, mtEntryT)) mt <- mkRWBramCoreForwarded();
    Fifo#(1, Tuple4#(mtIdxT, mtTagT, Bit#(16), Bit#(16))) mtRdFifo <- mkPipelineFifo;
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (3, unpack (0));

    rule processMtRead;
        Vector#(2, mtEntryT) mteVec = mt.rdResp;
        mt.deqRdResp;
        let {idx, tag, lengthHash, baseHash} = mtRdFifo.first;
        mtRdFifo.deq;
        EventsPrefetcher evt = unpack(0);

        if (mteVec[0].tag == tag) begin
            mtEntryT mte = mteVec[0];
            if (baseHash != mte.lastBoundsBaseHash && !mte.diffBaseCounted) begin
                $display ("%t Prefetcher Found PC %h with different bounds bases! (%h and %h)", $time, {tag, idx}, mte.lastBoundsBaseHash, baseHash);
                mte.diffBaseCounted = True;
                evt.evt_1 = 1;
            end
            if (lengthHash != mte.lastBoundsLenHash && !mte.diffLenCounted) begin
                $display ("%t Prefetcher Found PC %h with different bounds lengths! (%d and %d)", $time, {tag, idx}, mte.lastBoundsLenHash, lengthHash);
                mte.diffLenCounted = True;
                evt.evt_2 = 1;
            end
            mte.numLoads = (mte.numLoads == 255) ? 255 : mte.numLoads + 1;
            mte.lruMostRecent = True;
            mteVec[1].lruMostRecent = False;
            mteVec[0] = mte;
        end
        else if (mteVec[1].tag == tag) begin
            mtEntryT mte = mteVec[1];
            if (baseHash != mte.lastBoundsBaseHash && !mte.diffBaseCounted) begin
                $display ("%t Prefetcher Found PC %h with different bounds bases! (%h and %h)", $time, {tag, idx}, mte.lastBoundsBaseHash, baseHash);
                mte.diffBaseCounted = True;
                evt.evt_1 = 1;
            end
            if (lengthHash != mte.lastBoundsLenHash && !mte.diffLenCounted) begin
                $display ("%t Prefetcher Found PC %h with different bounds lengths! (%d and %d)", $time, {tag, idx}, mte.lastBoundsLenHash, lengthHash);
                mte.diffLenCounted = True;
                evt.evt_2 = 1;
            end
            mte.numLoads = (mte.numLoads == 255) ? 255 : mte.numLoads + 1;
            mte.lruMostRecent = True;
            mteVec[0].lruMostRecent = False;
            mteVec[1] = mte;
        end
        else begin
            Bit#(1) replaceIdx = 0;
            if (mteVec[0].lruMostRecent) replaceIdx = 1;
            else if (mteVec[1].lruMostRecent) replaceIdx = 0;
            mtEntryT mte = mteVec[replaceIdx];
            evt.evt_0 = 1;
            $display ("%t Prefetcher installing new MT entry idx %h replaceIdx %d ", $time, idx, replaceIdx, fshow(mteVec));
            if (mte.numLoads > 4 && mte.diffBaseCounted) begin
                evt.evt_3 = 1;
            end
            if (mte.numLoads > 4) begin
                evt.evt_4 = 1;
            end
            mte.tag = tag;
            mte.lastBoundsLenHash = lengthHash;
            mte.lastBoundsBaseHash = baseHash;
            mte.diffLenCounted = False;
            mte.diffBaseCounted = False;
            mte.numLoads = 0;
            mte.lruMostRecent = True;
            mteVec[(replaceIdx == 0) ? 1 : 0].lruMostRecent = False;
            mteVec[replaceIdx] = mte;
        end
        perf_events[1] <= evt;
        mt.wrReq(idx, mteVec);
    endrule

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        PCHash rotated = rotateBitsBy(pcHash, 31);
        mtIdxT idx = truncate(rotated);
        mtTagT tag = truncateLSB(rotated);
        Bit#(16) lengthHash = hash(boundsLength);
        Bit#(16) baseHash = hash(boundsVirtBase);
        mt.rdReq(idx);
        mtRdFifo.enq(tuple4(idx, tag, lengthHash, baseHash));

        if (`VERBOSE) $display("%t Prefetcher reportAccess %h pcHash %h rotatedpc %h boundslen %d boundsBase %h", $time, addr, pcHash, rotated, boundsLength, boundsVirtBase, fshow(hitMiss));
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);

    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr if (False);
        return unpack(0);
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return perf_events[0];
    endmethod
`endif

endmodule

typedef struct {
    tagT tag; 
    Bit#(8) numLoads;
    PCHash lastPCHash;
    Bit#(32) lastBoundsBaseHash;
    Bool diffPCCounted;
    Bool diffBaseCounted;
} Measurment2TableEntry#(type tagT) deriving (Bits, Eq, FShow);

module mkCapPCMeasurer(CheriPCPrefetcher) provisos (
    NumAlias#(mtEntries, 1024),
    Alias#(mtIdxT, Bit#(TLog#(mtEntries))),
    Alias#(mtTagT, Bit#(12)),
    Alias#(mtEntryT, Measurment2TableEntry#(mtTagT))
);
    RWBramCore#(mtIdxT, mtEntryT) mt <- mkRWBramCore();
    Fifo#(1, Tuple4#(mtIdxT, mtTagT, PCHash, Bit#(32))) mtRdFifo <- mkPipelineFifo;
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (3, unpack (0));

    rule processMtRead;
        mtEntryT mte = mt.rdResp;
        mt.deqRdResp;
        let {idx, tag, pcHash, baseHash} = mtRdFifo.first;
        mtRdFifo.deq;
        EventsPrefetcher evt = unpack(0);
        if (mte.tag == tag) begin
            if (baseHash != mte.lastBoundsBaseHash && !mte.diffBaseCounted) begin
                $display ("%t Prefetcher Found length %h with different bounds bases! (%h and %h)", $time, {tag, idx}, mte.lastBoundsBaseHash, baseHash);
                mte.diffBaseCounted = True;
                evt.evt_1 = 1;
            end
            if (pcHash != mte.lastPCHash && !mte.diffPCCounted) begin
                $display ("%t Prefetcher Found length %h with different PCs! (%d and %d)", $time, {tag, idx}, mte.lastPCHash, pcHash);
                mte.diffPCCounted = True;
                evt.evt_2 = 1;
            end
            mte.numLoads = (mte.numLoads == 255) ? 255 : mte.numLoads + 1;
        end
        else begin
            evt.evt_0 = 1;
            $display ("%t Prefetcher installing new MT entry", $time);
            if (mte.diffBaseCounted) begin
                evt.evt_3 = 1;
            end
            else if (mte.numLoads > 4) begin
                evt.evt_4 = 1;
            end
            mte.tag = tag;
            mte.lastPCHash = pcHash;
            mte.lastBoundsBaseHash = baseHash;
            mte.diffPCCounted = False;
            mte.diffBaseCounted = False;
            mte.numLoads = 0;
        end
        perf_events[1] <= evt;
        mt.wrReq(idx, mte);
    endrule

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        Bit#(32) lenHash = hash(boundsLength);
        mtIdxT idx = truncate(lenHash);
        mtTagT tag = truncateLSB(lenHash);
        Bit#(32) baseHash = hash(boundsVirtBase);
        mt.rdReq(idx);
        mtRdFifo.enq(tuple4(idx, tag, pcHash, baseHash));

        if (`VERBOSE) $display("%t Prefetcher reportAccess %h pcHash %h boundslen %d boundsBase %h", $time, addr, pcHash, boundsLength, boundsVirtBase, fshow(hitMiss));
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);

    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr if (False);
        return unpack(0);
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return perf_events[0];
    endmethod
`endif

endmodule


module mkCapLoggingPrefetcher#(Integer cacheLevel)(CheriPCPrefetcher) provisos ();
    Fifo#(4, Addr) prefetchRq <- mkOverflowPipelineFifo;
    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        if (cacheLevel == 1) begin
            $display("%t Prefetcher L1ReportAccess addr %h pcHash %h hitMiss %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, hitMiss, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
        end
        else begin
            $display("%t Prefetcher LLReportAccess addr %h pcHash %h hitMiss %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, hitMiss, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
        end
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
        MemTaggedData d1 = getTaggedDataAt(lineWithTags, 0);
        MemTaggedData d2 = getTaggedDataAt(lineWithTags, 1);
        MemTaggedData d3 = getTaggedDataAt(lineWithTags, 2);
        MemTaggedData d4 = getTaggedDataAt(lineWithTags, 3);

        CapPipe cap1 = fromMem(unpack(pack(d1)));
        CapPipe cap2 = fromMem(unpack(pack(d2)));
        CapPipe cap3 = fromMem(unpack(pack(d3)));
        CapPipe cap4 = fromMem(unpack(pack(d4)));

        LineMemDataOffset dataSel = getLineMemDataOffset(addr);
        MemTaggedData current = getTaggedDataAt(lineWithTags, dataSel);
        CapPipe selCap = fromMem(unpack(pack(current)));


        $display("%t Prefetcher logReportDataArrival requestAddr %h pcHash %h wasMiss %b wasPrefetch %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, wasMiss, wasPrefetch, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
        $display("%t Preftecher logReportDataArrivalCap capIndex 1 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d1.tag, getAddr(cap1), getOffset(cap1), getLength(cap1), getBase(cap1), getPerms(cap1));
        $display("%t Preftecher logReportDataArrivalCap capIndex 2 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d2.tag, getAddr(cap2), getOffset(cap2), getLength(cap2), getBase(cap2), getPerms(cap2));
        $display("%t Preftecher logReportDataArrivalCap capIndex 3 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d3.tag, getAddr(cap3), getOffset(cap3), getLength(cap3), getBase(cap3), getPerms(cap3));
        $display("%t Preftecher logReportDataArrivalCap capIndex 4 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d4.tag, getAddr(cap4), getOffset(cap4), getLength(cap4), getBase(cap4), getPerms(cap4));
        $display("%t Preftecher logReportDataArrivalSelectedCap capIndex %b tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, dataSel, current.tag, getAddr(selCap), getOffset(selCap), getLength(selCap), getBase(selCap), getPerms(selCap));

    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr if (False);
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, prefetchRq.first);
        prefetchRq.deq;
        return tuple3(prefetchRq.first, almightyCap, ?);
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return  unpack(0);
    endmethod
`endif

endmodule

module mkSimpleLogging#(Integer cacheLevel)(Prefetcher) provisos ();
    Fifo#(4, Addr) prefetchRq <- mkOverflowPipelineFifo;
    method Action reportAccess(Addr addr, HitOrMiss hitMiss, MemOp op);
        if (cacheLevel == 1) begin
            $display("%t Prefetcher L1ReportAccess addr %h hitMiss %b op %h", $time, addr, hitMiss, op);
        end
        else begin
            $display("%t Prefetcher LLReportAccess addr %h hitMiss %b op %h", $time, addr, hitMiss, op);
        end
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr if (False);
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, prefetchRq.first);
        prefetchRq.deq;
        return prefetchRq.first;
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return  unpack(0);
    endmethod
`endif

endmodule


`ifdef DATA_PREFETCHER_ALL_PREFETCH_FILTER

typedef struct {
    Bool valid;
    Bit#(tagBits) tag;
} PrefetchFilterEntry#(numeric type tagBits) deriving (Bits, Eq, FShow);

typedef struct {
    CapPipe cap;
    Bit#(3) depth;
} TlbInfo deriving (Bits, Eq, FShow);

module mkAllWithPrefetchFilterPrefetcher#(DTlbToPrefetcher toTlb, Parameter#(prefetchFilterTableSize) _)(CheriPCPrefetcher) 
provisos (
    NumAlias#(prefetchFilterIdxBits, TLog#(prefetchFilterTableSize)),
    NumAlias#(prefetchFilterTagBits, TSub#(CLineAddrSz, prefetchFilterIdxBits)),
    NumAlias#(prefetchFilterIdxTagBits, TAdd#(prefetchFilterIdxBits, prefetchFilterTagBits)),

    Alias#(prefetchFilterIdxT, Bit#(prefetchFilterIdxBits)),
    Alias#(prefetchFilterTagT, Bit#(prefetchFilterTagBits)),
    Alias#(prefetchFilterIdxTagT, Bit#(prefetchFilterIdxTagBits)),
    Alias#(prefetchFilterEntryT, PrefetchFilterEntry#(prefetchFilterTagBits)),

    Add#(k__, CLineAddrSz, TMul#(TDiv#(CLineAddrSz, prefetchFilterIdxTagBits), prefetchFilterIdxTagBits)),
    Add#(1, j__, TDiv#(CLineAddrSz, prefetchFilterIdxTagBits)),
    Add#(TLog#(prefetchFilterTableSize), l__, CLineAddrSz)
);
    Fifo#(4, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) prefetchQueue <- mkOverflowBypassFifo;

    Fifo#(4, TlbInfo) tlbLookupQueue <- mkOverflowPipelineFifo;

    Fifo#(1, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) dataForPrefetchFilterRdResp <- mkOverflowPipelineFifo;
    Fifo#(1, LineAddr) evictFromPrefetchFilterQ <- mkOverflowBypassFifo;
    Fifo#(1, LineAddr) dataForPrefetchFilterEvict <- mkPipelineFifo;
    RWBramCore#(prefetchFilterIdxT, prefetchFilterEntryT) prefetchFilterTable <- mkRWBramCoreForwarded;

    Reg#(Bool) initPrefetchFilterDone <- mkReg(False);
    Reg#(prefetchFilterIdxT) initPrefetchFilterIndex <- mkReg(0);

    rule doPrefetchFilterTableInit(!initPrefetchFilterDone);
        prefetchFilterEntryT pe;
        pe.valid = False;
        pe.tag = 0;

        prefetchFilterTable.wrReq(initPrefetchFilterIndex, pe);

        initPrefetchFilterIndex <= initPrefetchFilterIndex + 1;
        if(initPrefetchFilterIndex == maxBound) begin
            initPrefetchFilterDone <= True;
        end

    endrule

    function prefetchFilterIdxTagT getPrefetchFilterIdxTag(LineAddr lineAddr) = 
        hash(lineAddr);

    (* descending_urgency = "doTlbLookup, evictFromPrefetchFilterReadRq" *)
    rule evictFromPrefetchFilterReadRq;
        let lineAddr = evictFromPrefetchFilterQ.first;
        evictFromPrefetchFilterQ.deq;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(lineAddr);
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);

        if (`VERBOSE) $display("%t Prefetcher prefetchFilter evictReadRq idx %h", $time, prefetchFilterIdx);
        prefetchFilterTable.rdReq(prefetchFilterIdx);
        dataForPrefetchFilterEvict.enq(lineAddr);
    endrule

    (* descending_urgency = "processPrefetchFilterRdResp, evictFromPrefetchFilterRead" *)
    rule evictFromPrefetchFilterRead;
        let lineAddr = dataForPrefetchFilterEvict.first;
        dataForPrefetchFilterEvict.deq;

        prefetchFilterTable.deqRdResp;
        prefetchFilterEntryT prefetchFilterEntry = prefetchFilterTable.rdResp;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(lineAddr);
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);
        prefetchFilterTagT prefetchFilterTag = truncateLSB(prefetchFilterIdxTag);


        if (prefetchFilterEntry.valid && prefetchFilterEntry.tag == prefetchFilterTag) begin
            
            prefetchFilterEntry.valid = False;

            if (`VERBOSE) $display("%t Prefetcher prefetchFilter evictWrite idx %h tag %h", $time, prefetchFilterIdx, prefetchFilterTag);
            prefetchFilterTable.wrReq(prefetchFilterIdx, prefetchFilterEntry);
        end
    endrule

    rule processPrefetchFilterRdResp if (initPrefetchFilterDone);
        let {prefetchAddr, cap, prefetchOtherInfo} = dataForPrefetchFilterRdResp.first;
        dataForPrefetchFilterRdResp.deq;
        
        prefetchFilterTable.deqRdResp;
        prefetchFilterEntryT prefetchFilterEntry = prefetchFilterTable.rdResp;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(getLineAddr(prefetchAddr));
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);
        prefetchFilterTagT prefetchFilterTag = truncateLSB(prefetchFilterIdxTag);

        if (`VERBOSE) $display("%t prefetcher prefetchfilterRdResponse idx %h tag %h responseTag %h valid %h", $time, prefetchFilterIdx, prefetchFilterTag, prefetchFilterEntry.tag, prefetchFilterEntry.valid);


        if (!prefetchFilterEntry.valid || prefetchFilterEntry.tag != prefetchFilterTag) begin
            prefetchQueue.enq(tuple3(prefetchAddr, cap, prefetchOtherInfo));

            prefetchFilterEntryT pe;
            pe.valid = True;
            pe.tag = prefetchFilterTag;

            prefetchFilterTable.wrReq(prefetchFilterIdx, pe);
            if (`VERBOSE) $display("%t prefetcher prefetchfilter write idx %h tag %h valid %h", $time, prefetchFilterIdx, pe.tag, pe.valid);
        end
    endrule

    rule doTlbLookup;
        let tlbInfo = tlbLookupQueue.first;
        tlbLookupQueue.deq;

        toTlb.prefetcherReq(tlbInfo.cap, Valid(PrefetchOtherInfo {depth: tlbInfo.depth}));
        if (`VERBOSE) $display("%t Prefetcher doTlbLookup boundsVirtBase %h boundsOffset %h boundsLength %h depth %h", $time, getBase(tlbInfo.cap), getOffset(tlbInfo.cap), getLength(tlbInfo.cap), tlbInfo.depth);
    endrule

    rule getTlbResp;
        let resp = toTlb.prefetcherResp;
        toTlb.deqPrefetcherResp;

        if (`VERBOSE) $display("%t Prefetcher got TLB response: ", $time, fshow(resp));

        doAssert(isValid(resp.prefetchOtherInfo), "TLB response should have tagged prefetchOtherInfo");

        if (!resp.haveException && resp.paddr != 0) begin
            prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(getLineAddr(resp.paddr));
            prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);

            if (`VERBOSE) $display("%t prefetcher prefetchfilter RdReq prediction idx %h", $time, prefetchFilterIdx);
            prefetchFilterTable.rdReq(prefetchFilterIdx);
            dataForPrefetchFilterRdResp.enq(tuple3(resp.paddr, resp.cap, fromMaybe(?, resp.prefetchOtherInfo)));
        end
    endrule

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        $display("%t Prefetcher logReportAccess addr %h pcHash %h hitMiss %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, hitMiss, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
        MemTaggedData d1 = getTaggedDataAt(lineWithTags, 0);
        MemTaggedData d2 = getTaggedDataAt(lineWithTags, 1);
        MemTaggedData d3 = getTaggedDataAt(lineWithTags, 2);
        MemTaggedData d4 = getTaggedDataAt(lineWithTags, 3);

        CapPipe cap1 = fromMem(unpack(pack(d1)));
        CapPipe cap2 = fromMem(unpack(pack(d2)));
        CapPipe cap3 = fromMem(unpack(pack(d3)));
        CapPipe cap4 = fromMem(unpack(pack(d4)));

        LineMemDataOffset dataSel = getLineMemDataOffset(addr);
        MemTaggedData current = getTaggedDataAt(lineWithTags, dataSel);
        CapPipe selCap = fromMem(unpack(pack(current)));

        // Is pointer
        if (current.tag) begin
            case (prefetchOtherInfo) matches
                tagged Valid .prefetchInfo:
                    if (prefetchInfo.depth < 2) begin
                        tlbLookupQueue.enq(TlbInfo{cap: selCap, depth: prefetchInfo.depth + 1});
                    end
                tagged Invalid:
                    tlbLookupQueue.enq(TlbInfo{cap: selCap, depth: 0});
            endcase
        end

        $display("%t Prefetcher logReportDataArrival requestAddr %h pcHash %h wasMiss %b wasPrefetch %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, wasMiss, wasPrefetch, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
        $display("%t Preftecher logReportDataArrivalCap capIndex 1 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d1.tag, getAddr(cap1), getOffset(cap1), getLength(cap1), getBase(cap1), getPerms(cap1));
        $display("%t Preftecher logReportDataArrivalCap capIndex 2 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d2.tag, getAddr(cap2), getOffset(cap2), getLength(cap2), getBase(cap2), getPerms(cap2));
        $display("%t Preftecher logReportDataArrivalCap capIndex 3 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d3.tag, getAddr(cap3), getOffset(cap3), getLength(cap3), getBase(cap3), getPerms(cap3));
        $display("%t Preftecher logReportDataArrivalCap capIndex 4 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d4.tag, getAddr(cap4), getOffset(cap4), getLength(cap4), getBase(cap4), getPerms(cap4));
        $display("%t Preftecher logReportDataArrivalSelectedCap capIndex %b tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, dataSel, current.tag, getAddr(selCap), getOffset(selCap), getLength(selCap), getBase(selCap), getPerms(selCap));

    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, tpl_1(prefetchQueue.first));
        prefetchQueue.deq;

        return prefetchQueue.first;
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
            if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
            evictFromPrefetchFilterQ.enq(lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return  unpack(0);
    endmethod
`endif

endmodule
`endif

`ifdef DATA_PREFETCHER_CAP_PC_BACKWARDS
typedef struct {
    PCHash pcHash;
    Bit#(64) enqTime;
} TimelinessEntry deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(tagBits) tag;
    TimelinessEntry entry;
} TimelinessSetAssocEntry #(numeric type tagBits) deriving (Bits, Eq, FShow);

typedef Maybe#(TimelinessEntry) TimelinessTableResp;

interface TimelinessTable#(
    numeric type numOfWays,
    numeric type numOfSets
);
    method Action wrReq (Addr virtBase, PCHash pcHash, Bit#(64) enqTime);
    method Action rdReq (Addr virtBase, Bit#(64) targetTime);
    method ActionValue#(TimelinessTableResp) rdResp;
endinterface

module mkTimelinessTable(TimelinessTable#(numOfWays, numOfSets)) provisos (
    NumAlias#(idxBits, TLog#(numOfSets)),
    NumAlias#(tagBits, TSub#(64, idxBits)),
    NumAlias#(idxTagBits, TAdd#(idxBits, tagBits)),

    Alias#(wayT, Bit#(TLog#(numOfWays))),
    Alias#(indexT, Bit#(idxBits)),
    Alias#(tagT, Bit#(tagBits)),
    Alias#(indexTagT, Bit#(idxTagBits)),
    Alias#(repInfoT, wayT),
    
    Alias#(timelinessEntryT, TimelinessEntry),
    Alias#(timelinessSetAssocEntryT, TimelinessSetAssocEntry#(tagBits)),

    Add#(1, a__, numOfWays),
    Add#(b__, idxBits, 64),
    Add#(1, c__, TDiv#(64, idxTagBits)),
    Add#(d__, 64, TMul#(TDiv#(64, idxTagBits), idxTagBits))
);
    // See SetAssocTlb.bsv for basis of set associative data structure

    Vector#(numOfWays, RWBramCore#(indexT, timelinessSetAssocEntryT)) tRam <- replicateM(mkRWBramCoreForwarded);

    // Stores overflowing counter for fifo replacement of ways
    RWBramCore#(indexT, wayT) repBram <- mkRWBramCoreForwarded;
    RWBramCore#(indexT, wayT) repBramCopy <- mkRWBramCoreForwarded;
    
    Fifo#(1, Tuple3#(Addr, PCHash, Bit#(64))) writeQ <- mkPipelineFifo;
    Fifo#(1, Tuple2#(indexTagT, Bit#(64))) rdReqQ <- mkPipelineFifo; 

    Fifo#(1, TimelinessTableResp) rdRespQ <- mkBypassFifo;

    // initialize BRAM
    Reg#(Bool) initDone <- mkReg(False);
    Reg#(indexT) initIndex <- mkReg(0);

    rule doInit(!initDone);
        for(Integer i = 0; i < valueOf(numOfWays); i = i+1) begin
            tRam[i].wrReq(initIndex, TimelinessSetAssocEntry {
                valid: False,
                tag: 0,
                entry: TimelinessEntry {pcHash: 0, enqTime: 0}
            });
        end
        repBram.wrReq(initIndex, 0);
        repBramCopy.wrReq(initIndex, 0);
        initIndex <= initIndex + 1;
        if(initIndex == maxBound) begin
            initDone <= True;
        end
    endrule

    // Required to prevent to two replacment reads to same index reciving some value
    Ehr#(2, Maybe#(indexT)) pendReq <- mkEhr(Invalid);
    Reg#(Maybe#(indexT)) pendReq_deq = pendReq[0];
    Reg#(Maybe#(indexT)) pendReq_enq = pendReq[1];
    
    function indexTagT getIndexTag(Addr virtBase) = hash(virtBase);

    Wire#(Maybe#(indexT)) pendIndex <- mkBypassWire;
    (* fire_when_enabled, no_implicit_conditions *)
    rule setPendIndex;
        if(pendReq_deq matches tagged Valid .idx) begin
            pendIndex <= Valid (idx);
        end
        else begin
            pendIndex <= Invalid;
        end
    endrule

    function repInfoT nextReplacement(repInfoT current) =
        (current == fromInteger(valueOf(TSub#(numOfWays,1)))) ? 0 : current + 1;

    rule replacementResp(
        pendReq_deq matches tagged Valid .idx
    );
        pendReq_deq <= Invalid;

        let {virtBase, pcHash, enqTime} = writeQ.first;
        writeQ.deq;

        let repResp = repBram.rdResp;
        repBram.deqRdResp;

        // Write new way and update fifo
        indexTagT idxTag = getIndexTag(virtBase);
        indexT idx = truncate(idxTag);
        tagT tag = truncateLSB(idxTag);

        timelinessEntryT te;
        te.pcHash = pcHash;
        te.enqTime = enqTime;

        timelinessSetAssocEntryT tse;
        tse.valid = True;
        tse.tag = tag;
        tse.entry = te;

        if (`VERBOSE) $display("%t Prefetcher timeliness replacement repResp %d nextReplacement %d idx %h tag %h pcHash %h", $time, repResp, nextReplacement(repResp), idx, tag, pcHash);

        tRam[repResp].wrReq(idx, tse);

        repBram.wrReq(idx, nextReplacement(repResp));
        repBramCopy.wrReq(idx, nextReplacement(repResp));
    endrule

    // (* descending_urgency = "replacementResp, processRdReq" *) 
    rule processRdReq if (initDone);
        rdReqQ.deq;
        let {idxTag, targetTime} =  rdReqQ.first;
        indexT idx = truncate(idxTag);
        tagT tag = truncateLSB(idxTag);

        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            tRam[i].deqRdResp;
        end

        Vector#(numOfWays, timelinessSetAssocEntryT) resps; 
        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            resps[i] = tRam[i].rdResp;
        end

        repBramCopy.deqRdResp;
        let repResp = repBramCopy.rdResp; 
        
        let rotateNum = (repResp == 0) ? 0 : fromInteger(valueof(TSub#(numOfWays,1)))-repResp+1;
        
        // Rotate so index 0 is oldest
        let rotatedResp = rotateBy(resps, unpack(rotateNum));
        
        function timelinessSetAssocEntryT oldestValid(timelinessSetAssocEntryT a, timelinessSetAssocEntryT b);
            // If matches target time choose newer, otherwise choose oldest valid
            if (b.entry.enqTime < targetTime) begin
                return (b.valid && b.tag == tag) ? b : a;
            end
            else begin
                return (a.valid && a.tag == tag) ? a : b;
            end
        endfunction

        // function bool isMatch(timelinessSetAssocEntryT a)

        let result = fold(oldestValid, rotatedResp);
        if (`VERBOSE) $display("%t prefetcher timeliness table rdResp valid %b idx %h tag %h pcHash %h repResp %d rotateNum %d fshow ", $time, result.valid, idx, result.tag, result.entry.pcHash, repResp, rotateNum, fshow(resps), fshow(rotatedResp));

        rdRespQ.enq((result.valid && result.tag == tag) ? Valid (result.entry): Invalid);
    endrule

    method Action wrReq (Addr virtBase, PCHash pcHash, Bit#(64) enqTime) if(!isValid(pendReq_enq) && initDone);
        indexTagT idxTag = getIndexTag(virtBase);
        indexT idx = truncate(idxTag);
        tagT tag = truncateLSB(idxTag);

        // Implicit condition that there are no current in progress writes on idx
        when(pendIndex != Valid (idx), noAction);

        pendReq_enq <= Valid(idx);
        
        writeQ.enq(tuple3(virtBase, pcHash, enqTime));
        repBram.rdReq(idx);
    endmethod

    method Action rdReq(Addr virtBase, Bit#(64) targetTime) if(!isValid(pendReq_enq) && initDone);
        indexTagT idxTag = getIndexTag(virtBase);
        indexT idx = truncate(idxTag);
        tagT tag = truncateLSB(idxTag);

        when(pendIndex != Valid (idx), noAction);

        for (Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            tRam[i].rdReq(idx);
        end
        
        // Request replacement info as well for 
        repBramCopy.rdReq(idx);
        
        rdReqQ.enq(tuple2(idxTag, targetTime));
    endmethod

    method ActionValue#(TimelinessTableResp) rdResp();
        rdRespQ.deq;
        return rdRespQ.first; 
    endmethod


endmodule

typedef Bit#(3) Depth;

typedef struct {
    Bool valid;
    Addr parentVirtBase;
    Bit#(offsetBits) parentOffset;
    Bit#(64) parentTime;
    Bit#(tagBits) tag;
} BackwardsEntry #(numeric type tagBits, numeric type offsetBits) deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(offsetBits) parentOffset;
    Bit#(offsetBits) childOffset;
    Bit#(confidenceBits) confidence;
    PCHash childPCHash;
    Bit#(tagBits) tag; 
} PredictionEntry#(numeric type tagBits, numeric type offsetBits, numeric type confidenceBits) deriving (Bits, Eq, FShow);

typedef struct {
    PCHash pcHash;
    Bit#(offsetBits) parentOffset;
    Bit#(tagBits) tag; 
}  ConfidenceUpdateEntry#(numeric type tagBits, numeric type offsetBits) deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(tagBits) tag;
} PrefetchFilterEntry#(numeric type tagBits) deriving (Bits, Eq, FShow);

typedef struct {
    CapPipe cap;
    Maybe#(Bit#(offsetBits)) childOffset;
    predictionTableIdxTagT predIdxTag;
    PCHash childPCHash;
    Depth depth;
} TlbInfo#(numeric type offsetBits, type predictionTableIdxTagT) deriving (Bits, Eq, FShow);

module mkCapPCBackwards#(DTlbToPrefetcher toTlb, Parameter#(backwardsTableSize) _, Parameter#(timelinessTableWays) __, 
    Parameter#(timelinessTableSets) ___, Parameter#(predictionTableSize) ____, Parameter#(confidenceBits) _____,
    Parameter#(confidenceUpdateTableSize) ______, Parameter#(prefetchFilterTableSize) _______, Integer predictionReplacementConfidence, 
    Integer predictionPrefetchConfidence, Integer recursionDepth)(CheriPCPrefetcher) 
provisos (
    NumAlias#(backwardsTableIdxBits, TLog#(backwardsTableSize)),
    NumAlias#(backwardsTableTagBits, TSub#(64, backwardsTableIdxBits)),
    NumAlias#(backwardsTableIdxTagBits, TAdd#(backwardsTableIdxBits, backwardsTableTagBits)),
    NumAlias#(offsetBits, 64), // Could likely use a smaller number of bits for offset

    NumAlias#(timelinessIdxBits, TLog#(timelinessTableSets)),
    NumAlias#(timelinessTagBits, TSub#(64, timelinessIdxBits)),
    NumAlias#(timelinessIdxTagBits, TAdd#(timelinessIdxBits, timelinessTagBits)),
    
    NumAlias#(predictionTableIdxBits, TLog#(predictionTableSize)),
    NumAlias#(predictionTableTagBits, TSub#(32, predictionTableIdxBits)),
    NumAlias#(predictionTableIdxTagBits, TAdd#(predictionTableIdxBits, predictionTableTagBits)),

    NumAlias#(confidenceUpdateIdxBits, TLog#(confidenceUpdateTableSize)),
    NumAlias#(confidenceUpdateTagBits, TSub#(64, backwardsTableIdxBits)),
    NumAlias#(confidenceUpdateIdxTagBits, TAdd#(confidenceUpdateIdxBits, confidenceUpdateTagBits)),

    NumAlias#(prefetchFilterIdxBits, TLog#(prefetchFilterTableSize)),
    NumAlias#(prefetchFilterTagBits, TSub#(CLineAddrSz, prefetchFilterIdxBits)),
    NumAlias#(prefetchFilterIdxTagBits, TAdd#(prefetchFilterIdxBits, prefetchFilterTagBits)),
    
    Alias#(backwardsTableIdxT, Bit#(backwardsTableIdxBits)),
    Alias#(backwardsTableTagT, Bit#(backwardsTableTagBits)),
    Alias#(backwardsTableIdxTagT, Bit#(backwardsTableIdxTagBits)),
    Alias#(offsetT, Bit#(offsetBits)),
    Alias#(backwardsTableEntryT, BackwardsEntry#(backwardsTableTagBits, offsetBits)),

    Alias#(timelinessTableT, TimelinessTable#(timelinessTableWays, timelinessTableSets)),
    Alias#(timelinessTableEntryT, TimelinessEntry),

    Alias#(predictionTableIdxT, Bit#(predictionTableIdxBits)),
    Alias#(predictionTableTagT, Bit#(predictionTableTagBits)),
    Alias#(predictionTableIdxTagT, Bit#(predictionTableIdxTagBits)),
    Alias#(predictionTableEntryT, PredictionEntry#(predictionTableTagBits, offsetBits, confidenceBits)),

    Alias#(confidenceUpdateIdxT, Bit#(confidenceUpdateIdxBits)),
    Alias#(confidenceUpdateTagT, Bit#(confidenceUpdateTagBits)),
    Alias#(confidenceUpdateTableIdxTagT, Bit#(confidenceUpdateIdxTagBits)),
    Alias#(confidenceUpdateTableEntryT, ConfidenceUpdateEntry#(confidenceUpdateTagBits, offsetBits)),

    Alias#(prefetchFilterIdxT, Bit#(prefetchFilterIdxBits)),
    Alias#(prefetchFilterTagT, Bit#(prefetchFilterTagBits)),
    Alias#(prefetchFilterIdxTagT, Bit#(prefetchFilterIdxTagBits)),
    Alias#(prefetchFilterEntryT, PrefetchFilterEntry#(prefetchFilterTagBits)),

    Alias#(tlbInfoT, TlbInfo#(offsetBits, predictionTableIdxTagT)),

    Add#(a__, backwardsTableIdxBits, 64),
    Add#(1, b__, TDiv#(64, backwardsTableIdxTagBits)),
    Add#(c__, 64, TMul#(TDiv#(64, backwardsTableIdxTagBits), backwardsTableIdxTagBits)),

    Add#(1, d__, timelinessTableWays),
    Add#(e__, TLog#(timelinessTableSets), 64),
    Add#(1, f__, TDiv#(64, timelinessIdxTagBits)),
    Add#(g__, 64, TMul#(TDiv#(64, timelinessIdxTagBits), timelinessIdxTagBits)),

    Add#(h__, predictionTableIdxBits, 32),
    Add#(1, i__, TDiv#(32, predictionTableIdxTagBits)),
    Add#(j_, 32, TMul#(TDiv#(32, predictionTableIdxTagBits), predictionTableIdxTagBits)),
    Add#(k__, CLineAddrSz, TMul#(TDiv#(CLineAddrSz, prefetchFilterIdxTagBits), prefetchFilterIdxTagBits)),
    Add#(1, j__, TDiv#(CLineAddrSz, prefetchFilterIdxTagBits)),
    Add#(TLog#(prefetchFilterTableSize), l__, CLineAddrSz)
);
    Fifo#(4, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) prefetchQueue <- mkOverflowBypassFifo;

    Fifo#(1, Tuple2#(backwardsTableIdxT, backwardsTableEntryT)) backwardsEntryToWrite <- mkOverflowBypassFifo;
    Fifo#(1, Tuple5#(backwardsTableIdxTagT, offsetT, PCHash, Bit#(64), PCHash)) dataForBtReadReq <- mkOverflowBypassFifo;
    Fifo#(1, Tuple5#(backwardsTableTagT, offsetT, PCHash, Bit#(64), PCHash)) dataForBtReadResp <- mkPipelineFifo;
    RWBramCore#(backwardsTableIdxT, backwardsTableEntryT) backwardsTable <- mkRWBramCoreForwarded;
    
    Fifo#(2, Tuple3#(Addr, PCHash, Bit#(64))) dataForTtWriteEnq <- mkOverflowBypassFifo;
    Fifo#(1, Tuple4#(Addr, offsetT, offsetT, PCHash)) dataForTtRead <- mkPipelineFifo;
    timelinessTableT timelinessTable <- mkTimelinessTable;

    Fifo#(1, Tuple4#(predictionTableIdxTagT, offsetT, offsetT, PCHash)) dataForPredReplacmentRd <- mkPipelineFifo;
    Fifo#(1, Tuple4#(predictionTableIdxTagT, Addr, Addr, Depth)) dataForPredRdResp <- mkPipelineFifo;
    RWBramCore#(predictionTableIdxT, predictionTableEntryT) predictionTable <- mkRWBramCoreForwarded;
    RWBramCore#(predictionTableIdxT, predictionTableEntryT) predictionTableCopy <- mkRWBramCoreForwarded;

    Fifo#(1,  Tuple3#(predictionTableIdxTagT, Addr, Addr)) dataForPredRdReq <- mkOverflowBypassFifo;
    Fifo#(1,  Tuple4#(predictionTableIdxTagT, Addr, Addr, Depth)) dataForPredFromPrefetchRdReq <- mkOverflowBypassFifo;

    RWBramCore#(confidenceUpdateIdxT, confidenceUpdateTableEntryT) confidenceUpdateTable <- mkRWBramCoreForwarded;

    Fifo#(4, tlbInfoT) tlbLookupQueue <- mkOverflowPipelineFifo;

    Fifo#(2, tlbInfoT) dataForTlbLookupFromPrediction <- mkOverflowBypassFifo;
    Fifo#(2, tlbInfoT) dataForTlbLookupFromDataArrival <- mkOverflowBypassFifo;

    Fifo#(1, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) dataForPrefetchFilterRdResp <- mkOverflowPipelineFifo;
    Fifo#(1, LineAddr) evictFromPrefetchFilterQ <- mkOverflowBypassFifo;
    Fifo#(1, LineAddr) dataForPrefetchFilterEvict <- mkPipelineFifo;
    RWBramCore#(prefetchFilterIdxT, prefetchFilterEntryT) prefetchFilterTable <- mkRWBramCoreForwarded;

    Reg#(Bool) initBackwardsDone <- mkReg(False);
    Reg#(backwardsTableIdxT) initBackwardsIndex <- mkReg(0);

    Reg#(Bool) initPredictionDone <- mkReg(False);
    Reg#(predictionTableIdxT) initPredictionIndex <- mkReg(0);

    Reg#(Bool) initConfidenceUpdateDone <- mkReg(False);
    Reg#(confidenceUpdateIdxT) initConfidenceUpdateIndex <- mkReg(0);

    Reg#(Bool) initPrefetchFilterDone <- mkReg(False);
    Reg#(prefetchFilterIdxT) initPrefetchFilterIndex <- mkReg(0);

    rule doBackwardsTableInit(!initBackwardsDone);
        backwardsTableEntryT be;
        be.valid = False;
        be.parentVirtBase = 0;
        be.parentOffset = 0;
        be.tag = 0;
        be.parentTime = 0;

        backwardsTable.wrReq(initBackwardsIndex,  be);

        initBackwardsIndex <= initBackwardsIndex + 1;
        if(initBackwardsIndex == maxBound) begin
            initBackwardsDone <= True;
        end
    endrule

    rule doPredictionTableInit(!initPredictionDone);
        predictionTableEntryT pe;
        pe.parentOffset = 0;
        pe.childOffset = 0;
        pe.confidence = 0;
        pe.tag = 0;
        pe.childPCHash = 0;
        
        predictionTable.wrReq(initPredictionIndex, pe);
        predictionTableCopy.wrReq(initPredictionIndex, pe);

        initPredictionIndex <= initPredictionIndex + 1;
        if(initPredictionIndex == maxBound) begin
            initPredictionDone <= True;
        end
    endrule


    rule doConfidenceUpdateTableInit(!initConfidenceUpdateDone);
        confidenceUpdateTableEntryT ce;
        ce.pcHash = 0;
        ce.parentOffset = 0;
        ce.tag = 0;

        confidenceUpdateTable.wrReq(initConfidenceUpdateIndex,  ce);

        initConfidenceUpdateIndex <= initConfidenceUpdateIndex + 1;
        if(initConfidenceUpdateIndex == maxBound) begin
            initConfidenceUpdateDone <= True;
        end
    endrule

    rule doPrefetchFilterTableInit(!initPrefetchFilterDone);
        prefetchFilterEntryT pe;
        pe.valid = False;
        pe.tag = 0;

        prefetchFilterTable.wrReq(initPrefetchFilterIndex, pe);

        initPrefetchFilterIndex <= initPrefetchFilterIndex + 1;
        if(initPrefetchFilterIndex == maxBound) begin
            initPrefetchFilterDone <= True;
        end

    endrule

    function Bool initsDone() = 
        initBackwardsDone && initPredictionDone && initConfidenceUpdateDone && initPrefetchFilterDone;

    function backwardsTableIdxTagT getBackwardsIdxTag(Addr childVirtBase) = 
        hash(childVirtBase); 

    function predictionTableIdxTagT getPredictionIdxTag(PCHash pcHash) =
        hash(pcHash);

    function prefetchFilterIdxTagT getPrefetchFilterIdxTag(LineAddr lineAddr) = 
        hash(lineAddr);

    rule processPredictionReplacementRd;
        let {predIdxTag, parentOffset, childOffset, childPCHash} = dataForPredReplacmentRd.first;
        dataForPredReplacmentRd.deq;

        predictionTableIdxT predIdx = truncate(predIdxTag);
        predictionTableTagT predTag = truncateLSB(predIdxTag);

        predictionTableEntryT pe = predictionTable.rdResp;
        predictionTable.deqRdResp;
        
        if (`VERBOSE) $display("%t Prefetcher processPredictionReplacementRd inital response predIdxTag %h parentOffset %h childOffset %h confidence %h childPCHash %h", $time, predIdxTag, pe.parentOffset, pe.childOffset, pe.confidence, pe.childPCHash);


        if (pe.tag == predTag && pe.parentOffset == parentOffset && pe.childOffset == childOffset && pe.childPCHash == childPCHash) begin
            if (`VERBOSE) $display("%t prefetecher processPredictionReplacementRd match +1 oldConfidence %h idx %h tag %h childPCHash %h",$time, pe.confidence, predIdx, predTag, childPCHash);
            if (pe.confidence < maxBound) begin
                pe.confidence = pe.confidence + 1;
                predictionTable.wrReq(predIdx, pe);
                predictionTableCopy.wrReq(predIdx, pe);
            end
        end
        else begin // Decrease confidence or replace
            if (pe.confidence < fromInteger(predictionReplacementConfidence)) begin
                if (`VERBOSE) $display("%t prefetecher processPredictionReplacementRd replacement idx %h tag %h newParentOffset %h newChildOffset %h newChildPCHash oldParentOffset %h oldChildOffset %h oldChildPCHash %h", 
                                            $time, predIdx, predTag, parentOffset, childOffset, childPCHash, pe.parentOffset, pe.childOffset, pe.childPCHash);
                // Replace
                predictionTableEntryT peReplacement;
                peReplacement.parentOffset = parentOffset;
                peReplacement.childOffset = childOffset;
                peReplacement.confidence = 1;
                peReplacement.tag = predTag;
                peReplacement.childPCHash = childPCHash;
                predictionTable.wrReq(predIdx, peReplacement);
                predictionTableCopy.wrReq(predIdx, peReplacement);

            end 
            else begin
                    if (`VERBOSE) $display("%t   confidence oldConfidence %h idx %h tag %h oldParentOffset %h oldChildOffset %h", 
                                        $time, pe.confidence, predIdx, predTag, pe.parentOffset, pe.childOffset);
                // Decrease confidence
                doAssert(pe.confidence > 0, "Old confidence should be greater than 0");
                pe.confidence = pe.confidence - 1;
                predictionTable.wrReq(predIdx, pe);
                predictionTableCopy.wrReq(predIdx, pe);

            end 
        end
    endrule

    rule processTimelinessTableResp if (initsDone());
        // TODO: remove parentVirtBase as may be unecessary
        let {parentVirtBase, parentOffset, childOffset, childPCHash} = dataForTtRead.first;
        dataForTtRead.deq;

        let tResp <- timelinessTable.rdResp;
        case (tResp) matches
            tagged Valid .x: begin
                if (`VERBOSE) $display("%t Prefetcher timeliness table hit pcHash %h", $time, x.pcHash);

                predictionTableIdxTagT predIdxTag = getPredictionIdxTag(x.pcHash);
                predictionTableIdxT predIdx = truncate(predIdxTag);
                predictionTableTagT predTag = truncateLSB(predIdxTag);
                
                // Read existing predicition as only replace if below confidence
                dataForPredReplacmentRd.enq(tuple4(predIdxTag, parentOffset, childOffset, childPCHash));
                predictionTable.rdReq(predIdx);
            end
            tagged Invalid:
                if (`VERBOSE) $display("%t Prefetcher timeliness table miss", $time);
                // No ways with valid and tagged matching values
        endcase
    endrule

    rule processBtReadReq if (initsDone());
        let {bIdxTag, childOffset, pcHash, childMissArrivalTime, childPCHash} = dataForBtReadReq.first;
        dataForBtReadReq.deq;

        backwardsTableIdxT bIdx = truncate(bIdxTag);
        backwardsTableTagT bTag = truncateLSB(bIdxTag);
        
        dataForBtReadResp.enq(tuple5(bTag, childOffset, pcHash, childMissArrivalTime, childPCHash));
        backwardsTable.rdReq(bIdx);
    endrule

    rule processBtResp if (initsDone());
        let {bTag, childOffset, pcHash, childMissArrivalTime, childPCHash} = dataForBtReadResp.first;
        dataForBtReadResp.deq;
        let bResp = backwardsTable.rdResp;
        backwardsTable.deqRdResp;


        if (bResp.tag == bTag && bResp.valid) begin
            if (`VERBOSE) $display("%t Prefetcher backwards table hit tag %h parentVirtBase %h parentOffset %h childOffset %h childMissTime %h", $time, bResp.tag, bResp.parentVirtBase, bResp.parentOffset, childOffset, childMissArrivalTime);
            dataForTtRead.enq(tuple4(bResp.parentVirtBase, bResp.parentOffset, childOffset, childPCHash));

            timelinessTable.rdReq(bResp.parentVirtBase, bResp.parentTime - (childMissArrivalTime - bResp.parentTime)); 
        end
        else begin
            if (`VERBOSE) $display("%t Prefetcher backwards table collision or invalid tableTag %h ourTag %h valid %h", $time, bResp.tag, bTag, bResp.valid);
        end
    endrule

    // Prediction read to attempt prefetch
    rule processPredictionResponse;
        dataForPredRdResp.deq;
        let {predIdxTag, boundsLength, boundsVirtBase, depth} = dataForPredRdResp.first;
        predictionTableTagT predTag = truncateLSB(predIdxTag);

        predictionTableCopy.deqRdResp;
        let predResp = predictionTableCopy.rdResp;

        if (`VERBOSE) $display("%t Prefetcher processPredictionResponse inital response predIdxTag %h parentOffset %h childOffset %h confidence %h", $time, predIdxTag, predResp.parentOffset, predResp.childOffset, predResp.confidence);

        if (predResp.tag == predTag && predResp.confidence >= fromInteger(predictionPrefetchConfidence)
             && predResp.parentOffset < boundsLength) begin // TODO: check if off by one on offset check
            if (`VERBOSE) $display("%t Prefetcher processPredictionResponse tag match and valid offset predIdxTag %h parentOffset %h childOffset %h confidence %h virtBase %h", $time, predIdxTag, predResp.parentOffset, predResp.childOffset, predResp.confidence, boundsVirtBase);

            CapPipe cp = almightyCap;
            let cp1 = setAddr(cp, boundsVirtBase);
            let cp2 = setBounds(cp1.value, boundsLength);
            let cp3 = setOffset(cp2.value, predResp.parentOffset);

            tlbInfoT tlbInfo;
            tlbInfo.cap = cp3.value;
            tlbInfo.childOffset = Valid (predResp.childOffset);
            tlbInfo.predIdxTag = predIdxTag;
            tlbInfo.childPCHash = predResp.childPCHash;
            tlbInfo.depth = depth;
            

            dataForTlbLookupFromPrediction.enq(tlbInfo);
        end
    endrule

    // Need to add additional rule to prevent back-pressure and merge request from prediction response and data arrival
    rule tlbLookupFromPrediction if (initsDone());
        let tlbInfo = dataForTlbLookupFromPrediction.first;
        dataForTlbLookupFromPrediction.deq;

`ifndef PREFETCHER_RUN_ASIDE
        tlbLookupQueue.enq(tlbInfo);
`endif    
    endrule

    rule tlbLookupFromDataArrival if (initsDone());
        let tlbInfo = dataForTlbLookupFromDataArrival.first;
        dataForTlbLookupFromDataArrival.deq;

`ifndef PREFETCHER_RUN_ASIDE
        tlbLookupQueue.enq(tlbInfo);
`endif
    endrule

    rule processPrefetchFilterRdResp if (initsDone());
        let {prefetchAddr, cap, prefetchOtherInfo} = dataForPrefetchFilterRdResp.first;
        dataForPrefetchFilterRdResp.deq;
        
        prefetchFilterTable.deqRdResp;
        prefetchFilterEntryT prefetchFilterEntry = prefetchFilterTable.rdResp;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(getLineAddr(prefetchAddr));
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);
        prefetchFilterTagT prefetchFilterTag = truncateLSB(prefetchFilterIdxTag);

        if (`VERBOSE) $display("%t prefetcher prefetchfilterRdResponse idx %h tag %h responseTag %h valid %h", $time, prefetchFilterIdx, prefetchFilterTag, prefetchFilterEntry.tag, prefetchFilterEntry.valid);


        if (!prefetchFilterEntry.valid || prefetchFilterEntry.tag != prefetchFilterTag) begin
            prefetchQueue.enq(tuple3(prefetchAddr, cap, prefetchOtherInfo));

            prefetchFilterEntryT pe;
            pe.valid = True;
            pe.tag = prefetchFilterTag;

            prefetchFilterTable.wrReq(prefetchFilterIdx, pe);
            if (`VERBOSE) $display("%t prefetcher prefetchfilter write idx %h tag %h valid %h", $time, prefetchFilterIdx, pe.tag, pe.valid);
        end
    endrule

    rule doTlbLookup;
        let tlbInfo = tlbLookupQueue.first;
        tlbLookupQueue.deq;

        toTlb.prefetcherReq(tlbInfo.cap, Valid(PrefetchOtherInfo {childOffset: tlbInfo.childOffset, pcHash: tlbInfo.predIdxTag, childPCHash: tlbInfo.childPCHash, depth: tlbInfo.depth}));
        if (`VERBOSE) $display("%t Prefetcher doTlbLookup boundsVirtBase %h boundsOffset %h boundsLength %h childOffset %h", $time, getBase(tlbInfo.cap), getOffset(tlbInfo.cap), getLength(tlbInfo.cap), tlbInfo.childOffset);

    endrule

    rule getTlbResp;
        let resp = toTlb.prefetcherResp;
        toTlb.deqPrefetcherResp;

        if (`VERBOSE) $display("%t Prefetcher got TLB response: ", $time, fshow(resp));

        doAssert(isValid(resp.prefetchOtherInfo), "TLB response should have tagged prefetchOtherInfo");

        if (!resp.haveException && resp.paddr != 0) begin
            prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(getLineAddr(resp.paddr));
            prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);

            if (`VERBOSE) $display("%t prefetcher prefetchfilter RdReq prediction idx %h", $time, prefetchFilterIdx);
            prefetchFilterTable.rdReq(prefetchFilterIdx);
            dataForPrefetchFilterRdResp.enq(tuple3(resp.paddr, resp.cap, fromMaybe(?, resp.prefetchOtherInfo)));
        end
    endrule

    // (* descending_urgency = "processBtResp, processTimelinessTableResp, writeToTimeliness" *)
    rule writeToTimeliness;
        let {boundsVirtBase, pcHash, enqTime} = dataForTtWriteEnq.first;
        dataForTtWriteEnq.deq;

        timelinessTable.wrReq(boundsVirtBase, pcHash, enqTime);
    endrule

    rule writeToBackwards if (initsDone());
        let {bIdx, be} = backwardsEntryToWrite.first;
        backwardsEntryToWrite.deq;

        backwardsTable.wrReq(bIdx, be); 
        if (`VERBOSE) $display("%t Prefetcher Item added to backwards table parentVirtBase %h parentOffset %h idx %h childTag %h ", $time, be.parentVirtBase, be.parentOffset, bIdx, be.tag);

    endrule

    rule predictionTableReadRequest if (initsDone());
        let {predIdxTag, boundsLength, boundsVirtBase} = dataForPredRdReq.first;
        dataForPredRdReq.deq;

        predictionTableIdxT predIdx = truncate(predIdxTag);

        predictionTableCopy.rdReq(predIdx);
        dataForPredRdResp.enq(tuple4(predIdxTag, boundsLength, boundsVirtBase, 0));
    endrule

    rule predictionTableFromPrefetchReadRequest if (initsDone());
        let {predIdxTag, boundsLength, boundsVirtBase, depth} = dataForPredFromPrefetchRdReq.first;
        dataForPredFromPrefetchRdReq.deq;

        predictionTableIdxT predIdx = truncate(predIdxTag);

        predictionTableCopy.rdReq(predIdx);
        dataForPredRdResp.enq(tuple4(predIdxTag, boundsLength, boundsVirtBase, depth));
    endrule
    
    (* descending_urgency = "tlbLookupFromPrediction, tlbLookupFromDataArrival, evictFromPrefetchFilterReadRq" *)
    rule evictFromPrefetchFilterReadRq;
        let lineAddr = evictFromPrefetchFilterQ.first;
        evictFromPrefetchFilterQ.deq;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(lineAddr);
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);

        if (`VERBOSE) $display("%t Prefetcher prefetchFilter evictReadRq idx %h", $time, prefetchFilterIdx);
        prefetchFilterTable.rdReq(prefetchFilterIdx);
        dataForPrefetchFilterEvict.enq(lineAddr);
    endrule

    (* descending_urgency = "processPrefetchFilterRdResp, evictFromPrefetchFilterRead" *)
    rule evictFromPrefetchFilterRead;
        let lineAddr = dataForPrefetchFilterEvict.first;
        dataForPrefetchFilterEvict.deq;

        prefetchFilterTable.deqRdResp;
        prefetchFilterEntryT prefetchFilterEntry = prefetchFilterTable.rdResp;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(lineAddr);
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);
        prefetchFilterTagT prefetchFilterTag = truncateLSB(prefetchFilterIdxTag);


        if (prefetchFilterEntry.valid && prefetchFilterEntry.tag == prefetchFilterTag) begin
            
            prefetchFilterEntry.valid = False;

            if (`VERBOSE) $display("%t Prefetcher prefetchFilter evictWrite idx %h tag %h", $time, prefetchFilterIdx, prefetchFilterTag);
            prefetchFilterTable.wrReq(prefetchFilterIdx, prefetchFilterEntry);
        end
    endrule
    
    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        $display("%t Prefetcher logReportAccess addr %h pcHash %h hitMiss %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, hitMiss, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
        let enqTime <- $time;
        dataForTtWriteEnq.enq(tuple3(boundsVirtBase, pcHash, enqTime));
        
        predictionTableIdxTagT predIdxTag = getPredictionIdxTag(pcHash);
        dataForPredRdReq.enq(tuple3(predIdxTag, boundsLength, boundsVirtBase));
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);
        
        LineMemDataOffset dataSel = getLineMemDataOffset(addr);
        MemTaggedData current = getTaggedDataAt(lineWithTags, dataSel);
        CapPipe selCap = fromMem(unpack(pack(current)));

        if (wasMiss && !wasPrefetch) begin 
            backwardsTableIdxTagT bIdxTag = getBackwardsIdxTag(boundsVirtBase);

            let childMissArrivalTime <- $time;

            dataForBtReadReq.enq(tuple5(bIdxTag, boundsOffset, pcHash, childMissArrivalTime, pcHash));
        end

        // Populate backwards table
            // Prefetching from node to node so avoiding same virtBase
        if (!wasPrefetch && current.tag && getBase(selCap) != boundsVirtBase) begin
                    backwardsTableIdxTagT bIdxTag = getBackwardsIdxTag(getBase(selCap));
                    backwardsTableIdxT bIdx = truncate(bIdxTag);
                    backwardsTableTagT bTag = truncateLSB(bIdxTag);

                    backwardsTableEntryT be;
                    be.valid = True;
                    be.parentVirtBase = boundsVirtBase;
                    be.parentOffset = truncate(boundsOffset);
                    be.tag = bTag;
                    let parentTime <- $time;
                    be.parentTime = parentTime;
        
                    backwardsEntryToWrite.enq(tuple2(bIdx, be));
        end
    
        if (prefetchOtherInfo matches tagged Valid .prefetchInfo) begin
            if (prefetchInfo.childOffset matches tagged Valid .childOffset) begin
                if (current.tag && childOffset < saturating_truncate(getLength(selCap))) begin
                    // Prefetch just loaded child cap at child offset. TODO: Validate saturating_truncate is valid

                    CapPipe cp = almightyCap;
                    let cp1 = setAddr(cp, getBase(selCap));
                    let cp2 = setBounds(cp1.value, saturating_truncate(getLength(selCap)));
                    let cp3 = setOffset(cp2.value, childOffset);    
   

                    tlbInfoT tlbInfo;
                    tlbInfo.cap = cp3.value;
                    tlbInfo.childOffset = Invalid;
                    tlbInfo.predIdxTag = getPredictionIdxTag(prefetchInfo.pcHash);
                    tlbInfo.childPCHash = prefetchInfo.childPCHash;
                    tlbInfo.depth = prefetchInfo.depth;

                    dataForTlbLookupFromDataArrival.enq(tlbInfo);       
                    if (`VERBOSE ) $display("%t Prefetch childPrefetch virtBase %h childOffset %h ", $time, getBase(selCap), childOffset, fshow(prefetchOtherInfo));

                end
            end
            else if (prefetchInfo.depth <= 1) begin // Result of a child prefetch so start chaining
                predictionTableIdxTagT predIdxTag = getPredictionIdxTag(prefetchInfo.childPCHash);
                dataForPredFromPrefetchRdReq.enq(tuple4(predIdxTag, boundsLength, boundsVirtBase, prefetchInfo.depth + 1));
                if (`VERBOSE ) $display("%t Prefetcher triggering chain childPCHash %h", $time, prefetchInfo.childPCHash);

            end
        end 

        if (`VERBOSE) begin

            MemTaggedData d1 = getTaggedDataAt(lineWithTags, 0);
            MemTaggedData d2 = getTaggedDataAt(lineWithTags, 1);
            MemTaggedData d3 = getTaggedDataAt(lineWithTags, 2);
            MemTaggedData d4 = getTaggedDataAt(lineWithTags, 3);

            CapPipe cap1 = fromMem(unpack(pack(d1)));
            CapPipe cap2 = fromMem(unpack(pack(d2)));
            CapPipe cap3 = fromMem(unpack(pack(d3)));
            CapPipe cap4 = fromMem(unpack(pack(d4)));

            $display("%t Prefetcher logReportDataArrival requestAddr %h pcHash %h wasMiss %b wasPrefetch %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, wasMiss, wasPrefetch, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
            $display("%t Preftecher logReportDataArrivalCap capIndex 1 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d1.tag, getAddr(cap1), getOffset(cap1), getLength(cap1), getBase(cap1), getPerms(cap1));
            $display("%t Preftecher logReportDataArrivalCap capIndex 2 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d2.tag, getAddr(cap2), getOffset(cap2), getLength(cap2), getBase(cap2), getPerms(cap2));
            $display("%t Preftecher logReportDataArrivalCap capIndex 3 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d3.tag, getAddr(cap3), getOffset(cap3), getLength(cap3), getBase(cap3), getPerms(cap3));
            $display("%t Preftecher logReportDataArrivalCap capIndex 4 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d4.tag, getAddr(cap4), getOffset(cap4), getLength(cap4), getBase(cap4), getPerms(cap4));
            $display("%t Preftecher logReportDataArrivalSelectedCap capIndex %b tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, dataSel, current.tag, getAddr(selCap), getOffset(selCap), getLength(selCap), getBase(selCap), getPerms(selCap));
        end
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, tpl_1(prefetchQueue.first));
        prefetchQueue.deq;

        return prefetchQueue.first;
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
            if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
            evictFromPrefetchFilterQ.enq(lineAddr);
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return  unpack(0);
    endmethod
`endif

endmodule
`endif

`ifdef DATA_PREFETCHER_DEPENDENCE_PREFETCHER
typedef struct {
    Bit#(offsetBits) childOffset;
    PCHash childPC;
    Bit#(tagBits) tag; // parent PC Hash
} PredictionDepEntry#(numeric type tagBits, numeric type offsetBits) deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    PredictionDepEntry#(tagBits, offsetBits) entry;
} PredictionDepSetAssocEntry#(numeric type tagBits, numeric type offsetBits) deriving (Bits, Eq, FShow);

typedef struct {
    Vector#(numOfWays, predictionDepEntryT) entries;
    Vector#(numOfWays, Bool) hit;
} PredictionDepTableResp#(numeric type numOfWays, type wayT, type predictionDepEntryT) deriving (Bits, Eq, FShow);

interface PredictionDepTable#(
    numeric type numOfWays,
    numeric type numOfSets,
    numeric type offsetBits,
    type predictionDepEntryT,
    type predictionDepTableRespT
);
    method Action wrReq(PCHash parentPC, Bit#(offsetBits) childOffset, PCHash childPC);
    method Action rdReq(PCHash parentPC);
    method predictionDepTableRespT rdResp;
    method Action deqResp(Vector#(numOfWays, Bool) hitWays);
endinterface

module mkPredictionDepTable#(
        Bool randRep // random bit LRU replacment
    )(PredictionDepTable#(numOfWays, numOfSets, offsetBits, predictionDepEntryT, predictionDepTableRespT)) provisos (
    NumAlias#(idxBits, TLog#(numOfSets)),
    NumAlias#(tagBits, TSub#(32, idxBits)),
    NumAlias#(idxTagBits, TAdd#(idxBits, tagBits)),

    Alias#(wayT, Bit#(TLog#(numOfWays))),
    Alias#(indexT, Bit#(idxBits)),
    Alias#(tagT, Bit#(tagBits)),
    Alias#(indexTagT, Bit#(idxTagBits)),
    Alias#(repInfoT, Bit#(numOfWays)), // Bit lru
    Alias#(offsetT, Bit#(offsetBits)),
    
    Alias#(predictionDepEntryT, PredictionDepEntry#(tagBits, offsetBits)),
    Alias#(predictionDepSetAssocEntryT, PredictionDepSetAssocEntry#(tagBits, offsetBits)),
    Alias#(predictionDepTableRespT, PredictionDepTableResp#(numOfWays, wayT, predictionDepEntryT)),

    Add#(1, a__, numOfWays),
    Add#(b__, idxBits, 32),
    Add#(1, c__, TDiv#(32, idxTagBits)),
    Add#(d__, 32, TMul#(TDiv#(32, idxTagBits), idxTagBits))
);
    // See SetAssocTlb.bsv for basis of set associative data structure

    Vector#(numOfWays, RWBramCore#(indexT, predictionDepSetAssocEntryT)) predRam <- replicateM(mkRWBramCoreForwarded);

    RWBramCore#(indexT, repInfoT) repBram <- mkRWBramCoreForwarded;

    Fifo#(1, indexTagT) rdReqQ <- mkPipelineFifo;
    Fifo#(1, Tuple2#(indexT, predictionDepEntryT)) writeQ <- mkPipelineFifo;

    // randomly choose an LRU idx at replacement time
    Reg#(wayT) randIdx <- mkReg(0);
    if(randRep) begin
        rule incRandIdx;
            randIdx <= randIdx + 1;
        endrule
    end

    // initialize BRAM
    Reg#(Bool) initDone <- mkReg(False);
    Reg#(indexT) initIndex <- mkReg(0);

    rule doInit if (!initDone);
        for(Integer i = 0; i < valueOf(numOfWays); i = i+1) begin
            predictionDepEntryT predEntry;
            predEntry.childOffset = 0;
            predEntry.childPC = 0;
            predEntry.tag = 0;
            
            predictionDepSetAssocEntryT predSetEntry;
            predSetEntry.valid = False;
            predSetEntry.entry = predEntry;

            predRam[i].wrReq(initIndex, predSetEntry);
        end
        repBram.wrReq(initIndex, 0);

        initIndex <= initIndex + 1;
        if(initIndex == maxBound) begin
            initDone <= True;
        end
    endrule

    function indexTagT getIndexTag(PCHash pc) = hash(pc);

    function repInfoT lruBitUpdate(repInfoT repInfo, wayT way);
        repInfo[way] = 1;
        if(repInfo == maxBound) begin
            repInfo = 0;
            repInfo[way] = 1;
        end
        return repInfo;
    endfunction

    rule processWrReq;
        let {idx, writeEntry} = writeQ.first;
        writeQ.deq;

        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            predRam[i].deqRdResp;
        end

        Vector#(numOfWays, Bool) validVec;
        Vector#(numOfWays, predictionDepEntryT) entryVec;

        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            let r = predRam[i].rdResp;
            validVec[i] = r.valid;
            entryVec[i] = r.entry;
        end

        repInfoT repInfo = repBram.rdResp;
        repBram.deqRdResp;

        function Bool sameEntry(wayT w);
            let en = entryVec[w];
            Bool entry_match = en.tag == writeEntry.tag &&
                             en.childOffset == writeEntry.childOffset &&  
                             en.childPC == writeEntry.childPC;
            return validVec[w] && entry_match;
        endfunction


        Vector#(numOfWays, wayT) wayVec = genWith(fromInteger);

        function Bool isFalse(Bool b) = !b;

        if(find(sameEntry, wayVec) matches tagged Valid .way) begin
            // entry exists, update rep info
            repBram.wrReq(idx, lruBitUpdate(repInfo, way));

            // if (writeEntry.childPC != entryVec[way].childPC) begin
            //     if (`VERBOSE) $display("%t Prefetcher processWrReq found same entry replace child old %h new %h ", $time, entryVec[way].childPC, writeEntry.childPC);
                
            //     predictionDepSetAssocEntryT predSetEntry;
            //     predSetEntry.valid = True;
            //     predSetEntry.entry = writeEntry;
                
            //     predRam[way].wrReq(idx, predSetEntry);
            // end

            if (`VERBOSE) $display("%t Prefetcher processWrReq found same entry rdReq lruBitUpdate %h entry ", $time, lruBitUpdate(repInfo, way), writeEntry);

        end
        else begin
            wayT repWay;
            if(findIndex(isFalse, validVec) matches tagged Valid .repWayIdx) begin
                // get empty slot
                repWay = pack(repWayIdx);
                if (`VERBOSE) $display("%t Prefetcher processWrReq found empty slot replaceIndex %h", $time, repWay);

            end
            else begin
                // find LRU slot (lruBit[i] = 0 means i is LRU slot)
                Vector#(numOfWays, Bool) isLRU = unpack(~repInfo);
                if(randRep && isLRU[randIdx]) begin
                    repWay = randIdx;
                end
                else if(findIndex(id, isLRU) matches tagged Valid .repWayIdx) begin
                    repWay = pack(repWayIdx);
                end
                else begin
                    repWay = 0; // this is actually impossible
                    doAssert(False, "must have at least 1 LRU slot");
                end
                if (`VERBOSE) $display("%t Prefetcher processWrReq found lru slot replaceIndex %h", $time, repWay);

            end
            repBram.wrReq(idx, lruBitUpdate(repInfo, repWay));

            predictionDepSetAssocEntryT predSetEntry;
            predSetEntry.valid = True;
            predSetEntry.entry = writeEntry;

            predRam[repWay].wrReq(idx, predSetEntry);
            if (`VERBOSE) $display("%t Prefetcher processWrReq replacement repWay %h lruBitUpdate %h entry ", $time, repWay, lruBitUpdate(repInfo, repWay), fshow(predSetEntry));
        end
    endrule


    method Action wrReq(PCHash parentPC, offsetT childOffset, PCHash childPC) if(initDone);
        indexTagT idxTag = getIndexTag(parentPC);
        indexT idx = truncate(idxTag);
        tagT tag = truncateLSB(idxTag);
        
        predictionDepEntryT predEntry;
        predEntry.childOffset = childOffset;
        predEntry.childPC = childPC;
        predEntry.tag = tag;

        writeQ.enq(tuple2(idx, predEntry));
        repBram.rdReq(idx);

        for (Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            predRam[i].rdReq(idx);
        end

        if (`VERBOSE) $display("%t Prefetcher predTable wrReq idxTag %h predEntry ", $time, idxTag, predEntry);
    endmethod

    method Action rdReq(PCHash parentPC) if(initDone);
        indexTagT idxTag = getIndexTag(parentPC);
        indexT idx = truncate(idxTag);
        tagT tag = truncateLSB(idxTag);

        for (Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            predRam[i].rdReq(idx);
        end
        
        if (`VERBOSE) $display("%t Prefetcher predTable rdReq parentPC %h", $time, parentPC);

        repBram.rdReq(idx);
        rdReqQ.enq(idxTag);
    endmethod

    method predictionDepTableRespT rdResp();
        // get all the tlb ram resp & LRU
        Vector#(numOfWays, predictionDepSetAssocEntryT) entries;
        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            entries[i] = predRam[i].rdResp;
        end

        let idxTag = rdReqQ.first;
        tagT tag = truncateLSB(idxTag);

        function Bool entryHit(wayT i);
            predictionDepSetAssocEntryT en = entries[i];
            Bool tagMatch = en.entry.tag == tag;
            return en.valid && tagMatch;
        endfunction
        
        predictionDepTableRespT predTableResp;

        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            if (entryHit(fromInteger(i))) begin
                predTableResp.hit[i] = True;
                predTableResp.entries[i] = entries[i].entry;
            end
            else begin
                predTableResp.hit[i] = False;
                predTableResp.entries[i] = ?;
            end
        end

        // if (`VERBOSE) $display("%t Prefetcher predTable rdResp idxTag %h", $time, idxTag, fshow(predTableResp));
        
        return predTableResp;
    endmethod

    method Action deqResp(Vector#(numOfWays, Bool) hitWays) if(initDone);
        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            predRam[i].deqRdResp;
        end

        repInfoT repInfo = repBram.rdResp;
        repBram.deqRdResp;

        let idxTag = rdReqQ.first;
        rdReqQ.deq;

        Bool overflowStop = False; // If bitLru overflowed to 0 and written full hitWays stop
        for(Integer i = 0; i < valueof(numOfWays); i = i+1) begin
            if (hitWays[i] && !overflowStop) begin
                repInfo[i] = 1;
                if(repInfo == maxBound) begin
                    if (!all(id, hitWays)) begin // Ensure that at least one value is 0
                        // If not all ways have been hit, then make bit-lru equal way which have been hit on overflow
                        repInfo = pack(hitWays);
                        overflowStop = True;
                    end
                    else begin
                        repInfo = 0;
                        repInfo[i] = 1;
                    end
                end
            end
        end
        
        if (`VERBOSE) $display("%t Prefetcher predTable deqResp idxTag %h, repInfo ", $time, idxTag, repInfo);

        if (any(id, hitWays)) begin
            indexT idx = truncate(idxTag);
            repBram.wrReq(idx, repInfo);
        end
    endmethod
endmodule



typedef struct {
    Bool valid;
    PCHash parentPC;
    Bit#(tagBits) tag;
} BackwardsDepEntry #(numeric type tagBits) deriving (Bits, Eq, FShow);

typedef struct {
    backwardsTableIdxTagT bIdxTag;
    Bit#(offsetBits) childOffset;
    PCHash childPC;
} BackwardsDepReadRespData #(type backwardsTableIdxTagT, numeric type offsetBits) deriving (Bits, Eq, FShow);

typedef struct {
    PCHash parentPC;
    CapPipe filledCap; // TODO: optimised to use lineCaps and index 
    Bit#(depthBits) depth;
    // CLine lineWithTags;
    // LineAddr lineAddr;
} PredictionDepReadRespData#(numeric type depthBits) deriving (Bits, Eq, FShow);

typedef struct {
    CapPipe cap;
    Bit#(3) depth;
    PCHash childPC;
} TlbInfo deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(tagBits) tag;
} PrefetchFilterEntry#(numeric type tagBits) deriving (Bits, Eq, FShow);


typedef struct {
    Bool valid;
    PCHash recentPC; // Most recent PC cap size was accessed at
    Bit#(tagBits) tag;
} CapSizeEntry#(numeric type tagBits) deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid; // Cap has valid tag and isn't directly addressed cap but on other other caps 
    CapPipe cap;
} CapSizePrefetchQuery deriving (Bits, Eq, FShow);

module mkDependancePrefetcher#(DTlbToPrefetcher toTlb, Parameter#(backwardsTableSize) _, Parameter#(predictionTableWays) __, 
    Parameter#(predictionTableSets) ___, Parameter#(prefetchFilterTableSize) ____, Parameter#(capSizeTableSize) _____, Integer recursionDepth)(CheriPCPrefetcher) 
provisos (
    NumAlias#(prefetchFilterIdxBits, TLog#(prefetchFilterTableSize)),
    NumAlias#(prefetchFilterTagBits, TSub#(CLineAddrSz, prefetchFilterIdxBits)),
    NumAlias#(prefetchFilterIdxTagBits, TAdd#(prefetchFilterIdxBits, prefetchFilterTagBits)),


    NumAlias#(backwardsTableIdxBits, TLog#(backwardsTableSize)),
    NumAlias#(backwardsTableTagBits, TSub#(64, backwardsTableIdxBits)),
    NumAlias#(backwardsTableIdxTagBits, TAdd#(backwardsTableIdxBits, backwardsTableTagBits)),
    NumAlias#(offsetBits, 64), // Could likely use a smaller number of bits for offset

    NumAlias#(predictionTableIdxBits, TLog#(predictionTableSets)),
    NumAlias#(predictionTableTagBits, TSub#(32, predictionTableIdxBits)),
    NumAlias#(predictionTableIdxTagBits, TAdd#(predictionTableIdxBits, predictionTableTagBits)),
    NumAlias#(predictionWayBits, TLog#(predictionTableWays)),

    NumAlias#(capSizeTableIdxBits, TLog#(capSizeTableSize)),
    NumAlias#(capSizeTableTagBits, TSub#(64, capSizeTableIdxBits)),
    NumAlias#(capSizeTableIdxTagBits, TAdd#(capSizeTableIdxBits, capSizeTableTagBits)),

    NumAlias#(depthBits, 3),


    Alias#(prefetchFilterIdxT, Bit#(prefetchFilterIdxBits)),
    Alias#(prefetchFilterTagT, Bit#(prefetchFilterTagBits)),
    Alias#(prefetchFilterIdxTagT, Bit#(prefetchFilterIdxTagBits)),
    Alias#(prefetchFilterEntryT, PrefetchFilterEntry#(prefetchFilterTagBits)),

    Alias#(backwardsTableIdxT, Bit#(backwardsTableIdxBits)),
    Alias#(backwardsTableTagT, Bit#(backwardsTableTagBits)),
    Alias#(backwardsTableIdxTagT, Bit#(backwardsTableIdxTagBits)),
    Alias#(offsetT, Bit#(offsetBits)),
    Alias#(backwardsTableEntryT, BackwardsDepEntry#(backwardsTableTagBits)),

    Alias#(backwardsDepReadRespDataT, BackwardsDepReadRespData#(backwardsTableIdxTagT, offsetBits)),

    Alias#(predictionDepEntryT, PredictionDepEntry#(predictionTableTagBits, offsetBits)),
    Alias#(predictionWayT, Bit#(predictionWayBits)),
    Alias#(predictionDepTableRespT, PredictionDepTableResp#(predictionTableWays, predictionWayT, predictionDepEntryT)),
    Alias#(predictionTableT, PredictionDepTable#(predictionTableWays, predictionTableSets, offsetBits, predictionDepEntryT, predictionDepTableRespT)), 

    Alias#(predictionDepReadRespDataT, PredictionDepReadRespData#(depthBits)),

    Alias#(capSizeTableIdxT, Bit#(capSizeTableIdxBits)),
    Alias#(capSizeTableTagT, Bit#(capSizeTableTagBits)),
    Alias#(capSizeTableIdxTagT, Bit#(capSizeTableIdxTagBits)),
    Alias#(capSizeTableEntryT, CapSizeEntry#(capSizeTableTagBits)),

    NumAlias#(capSizeQLineNumElements, 4),
    NumAlias#(capSizeQIdxBits, TLog#(capSizeQLineNumElements)),
    Alias#(capSizeQIdxT, Bit#(capSizeQIdxBits)),

    Alias#(depthT, Bit#((depthBits))),

    Add#(a__, backwardsTableIdxBits, 64),
    Add#(1, b__, TDiv#(64, backwardsTableIdxTagBits)),
    Add#(c__, 64, TMul#(TDiv#(64, backwardsTableIdxTagBits), backwardsTableIdxTagBits)),

    Add#(1, d__, predictionTableWays),
    Add#(e__, predictionTableIdxBits, 32),
    Add#(1, f__, TDiv#(32, predictionTableIdxTagBits)),
    Add#(g__, 32, TMul#(TDiv#(32, predictionTableIdxTagBits), predictionTableIdxTagBits)),

    Add#(h__, CLineAddrSz, TMul#(TDiv#(CLineAddrSz, prefetchFilterIdxTagBits), prefetchFilterIdxTagBits)),
    Add#(1, i__, TDiv#(CLineAddrSz, prefetchFilterIdxTagBits)),
    Add#(TLog#(prefetchFilterTableSize), j__, CLineAddrSz),

    Add#(l__, capSizeTableIdxBits, 64),
    Add#(1, k__, TDiv#(64, capSizeTableIdxTagBits)),
    Add#(m__, 64, TMul#(TDiv#(64, capSizeTableIdxTagBits), capSizeTableIdxTagBits))

);


    Fifo#(1, Tuple2#(backwardsTableIdxT, backwardsTableEntryT)) backwardsEntryToWrite <- mkOverflowBypassFifo;
    Fifo#(1, backwardsDepReadRespDataT) dataForBtReadReq <- mkOverflowBypassFifo;
    Fifo#(1, backwardsDepReadRespDataT) dataForBtReadResp <- mkPipelineFifo;
    RWBramCore#(backwardsTableIdxT, backwardsTableEntryT) backwardsTable <- mkRWBramCoreForwarded;


    Fifo#(1, predictionDepReadRespDataT) dataForPredRdReqFromShortcut <- mkOverflowBypassFifo;
    Fifo#(1, predictionDepReadRespDataT) dataForPredRdReqFromDataArrival <- mkOverflowBypassFifo;
    Fifo#(1, predictionDepReadRespDataT) dataForPredRdReqFromCapSize <- mkOverflowBypassFifo;

    Fifo#(1, predictionDepReadRespDataT) dataForPredRdReq <- mkOverflowBypassFifo;
    Fifo#(1, predictionDepReadRespDataT) dataForPredRdResp <- mkPipelineFifo;
    predictionTableT predictionTable <- mkPredictionDepTable(True);

    Fifo#(1, predictionDepTableRespT) currentPredictionTableResp <- mkPipelineFifo;
    Fifo#(1, predictionDepReadRespDataT) currentPredictionTableRespData <- mkPipelineFifo;
    Reg#(Vector#(predictionTableWays, Bool)) predRespWaysUsed <- mkReg(replicate(False));

    Fifo#(4, TlbInfo) tlbLookupQueue <- mkOverflowPipelineFifo;

    Fifo#(4, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) prefetchQueue <- mkOverflowBypassFifo;


    Fifo#(1, Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) dataForPrefetchFilterRdResp <- mkOverflowPipelineFifo;
    Fifo#(1, LineAddr) evictFromPrefetchFilterQ <- mkOverflowBypassFifo;
    Fifo#(1, LineAddr) dataForPrefetchFilterEvict <- mkPipelineFifo;
    RWBramCore#(prefetchFilterIdxT, prefetchFilterEntryT) prefetchFilterTable <- mkRWBramCoreForwarded;

    Fifo#(4, Vector#(capSizeQLineNumElements, CapSizePrefetchQuery)) capSizePrefetchQueryQueue <- mkOverflowPipelineFifo;
    Fifo#(1, Vector#(capSizeQLineNumElements, CapSizePrefetchQuery)) currentCapSizePrefetchQuery <- mkBypassFifo;
    Fifo#(1, CapSizePrefetchQuery) dataForCapSizeRdResp <- mkPipelineFifo;
    Reg#(Vector#(capSizeQLineNumElements, Bool)) currentCapSizePrefetchQueryUsed <- mkReg(replicate(False));
    RWBramCore#(capSizeTableIdxT, capSizeTableEntryT) capSizeTable <- mkRWBramCoreForwarded;

    // Initalisation
    Reg#(Bool) initBackwardsDone <- mkReg(False);
    Reg#(backwardsTableIdxT) initBackwardsIndex <- mkReg(0);

    rule doBackwardsTableInit(!initBackwardsDone);
        backwardsTableEntryT be;
        be.valid = False;
        be.tag = 0;
        be.parentPC = 0;

        backwardsTable.wrReq(initBackwardsIndex,  be);

        initBackwardsIndex <= initBackwardsIndex + 1;
        if(initBackwardsIndex == maxBound) begin
            initBackwardsDone <= True;
        end
    endrule

    Reg#(Bool) initPrefetchFilterDone <- mkReg(False);
    Reg#(prefetchFilterIdxT) initPrefetchFilterIndex <- mkReg(0);

    rule doPrefetchFilterTableInit(!initPrefetchFilterDone);
        prefetchFilterEntryT pe;
        pe.valid = False;
        pe.tag = 0;

        prefetchFilterTable.wrReq(initPrefetchFilterIndex, pe);

        initPrefetchFilterIndex <= initPrefetchFilterIndex + 1;
        if(initPrefetchFilterIndex == maxBound) begin
            initPrefetchFilterDone <= True;
        end
    endrule

    Reg#(Bool) initCapSizeTableDone <- mkReg(False);
    Reg#(capSizeTableIdxT) initCapSizeTableIndex <- mkReg(0);

    rule doCapSizeTableInit(!initCapSizeTableDone);
        capSizeTableEntryT ce;
        ce.valid = False;
        ce.recentPC = 0;
        ce.tag = 0;

        capSizeTable.wrReq(initCapSizeTableIndex, ce);

        initCapSizeTableIndex <= initCapSizeTableIndex + 1;
        if(initCapSizeTableIndex == maxBound) begin
            initCapSizeTableDone <= True;
        end
    endrule

    // Functions
    function Bool initsDone() = 
        initBackwardsDone && initPrefetchFilterDone && initCapSizeTableDone;

    function backwardsTableIdxTagT getBackwardsIdxTag(Addr childVirtBase) = 
        hash(childVirtBase); 

    function prefetchFilterIdxTagT getPrefetchFilterIdxTag(LineAddr lineAddr) = 
        hash(lineAddr);

    function capSizeTableIdxTagT getCapSizeTableIdxTag(Addr boundsLength) = 
        hash(boundsLength);

    function Bool canPrefetch(predictionWayT way) = 
        !predRespWaysUsed[way] && currentPredictionTableResp.first.hit[way];

    function canDoAnyPrefetch();
        Vector#(predictionTableWays, predictionWayT) wayVec = genWith(fromInteger);

        return any(canPrefetch, wayVec);
    endfunction

    // Rules
    // Prefetch Filter
    (* descending_urgency = "processPrefetchFilterRdResp, evictFromPrefetchFilterRead" *)
    rule evictFromPrefetchFilterRead;
        let lineAddr = dataForPrefetchFilterEvict.first;
        dataForPrefetchFilterEvict.deq;

        prefetchFilterTable.deqRdResp;
        prefetchFilterEntryT prefetchFilterEntry = prefetchFilterTable.rdResp;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(lineAddr);
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);
        prefetchFilterTagT prefetchFilterTag = truncateLSB(prefetchFilterIdxTag);


        if (prefetchFilterEntry.valid && prefetchFilterEntry.tag == prefetchFilterTag) begin
            
            prefetchFilterEntry.valid = False;

            if (`VERBOSE) $display("%t Prefetcher prefetchFilter evictWrite idx %h tag %h", $time, prefetchFilterIdx, prefetchFilterTag);
            prefetchFilterTable.wrReq(prefetchFilterIdx, prefetchFilterEntry);
        end
    endrule

    rule processPrefetchFilterRdResp if (initPrefetchFilterDone);
        let {prefetchAddr, cap, prefetchOtherInfo} = dataForPrefetchFilterRdResp.first;
        dataForPrefetchFilterRdResp.deq;
        
        prefetchFilterTable.deqRdResp;
        prefetchFilterEntryT prefetchFilterEntry = prefetchFilterTable.rdResp;

        prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(getLineAddr(prefetchAddr));
        prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);
        prefetchFilterTagT prefetchFilterTag = truncateLSB(prefetchFilterIdxTag);

        if (`VERBOSE) $display("%t prefetcher prefetchfilterRdResponse idx %h tag %h responseTag %h valid %h", $time, prefetchFilterIdx, prefetchFilterTag, prefetchFilterEntry.tag, prefetchFilterEntry.valid);


        if (!prefetchFilterEntry.valid || prefetchFilterEntry.tag != prefetchFilterTag) begin
            prefetchQueue.enq(tuple3(prefetchAddr, cap, prefetchOtherInfo));

            prefetchFilterEntryT pe;
            pe.valid = True;
            pe.tag = prefetchFilterTag;

            prefetchFilterTable.wrReq(prefetchFilterIdx, pe);
            if (`VERBOSE) $display("%t prefetcher prefetchfilter write idx %h tag %h valid %h", $time, prefetchFilterIdx, pe.tag, pe.valid);
        end
    endrule

    // Backwards table
    rule writeToBackwards if (initsDone());
        let {bIdx, be} = backwardsEntryToWrite.first;
        backwardsEntryToWrite.deq;

        backwardsTable.wrReq(bIdx, be); 
        if (`VERBOSE) $display("%t Prefetcher Item added to backwards table idx %h childTag %h parentPC %h", $time, bIdx, be.tag, be.parentPC);
    endrule

    rule processBtReadReq if (initsDone());
        let backwardsRespData = dataForBtReadReq.first;
        dataForBtReadReq.deq;

        backwardsTableIdxT bIdx = truncate(backwardsRespData.bIdxTag);
        
        dataForBtReadResp.enq(backwardsRespData);
        backwardsTable.rdReq(bIdx);

        if (`VERBOSE) $display("%t Prefetcher processBtReadReq ", $time, fshow(backwardsRespData));

    endrule

    rule processBtResp;
        let backwardsRespData = dataForBtReadResp.first;
        dataForBtReadResp.deq;

        let bResp = backwardsTable.rdResp;
        backwardsTable.deqRdResp;

        backwardsTableTagT bTag = truncateLSB(backwardsRespData.bIdxTag);

        if (bResp.tag == bTag && bResp.valid) begin
            if (`VERBOSE) $display("%t Prefetcher backwards table hit tag %h childOffset %h pc %h", $time, bResp.tag, backwardsRespData.childOffset, backwardsRespData.childPC);
            

            predictionTable.wrReq(bResp.parentPC, backwardsRespData.childOffset, backwardsRespData.childPC);
            // TODO: write to the prediction table with potential replacement
        end
        else begin
            if (`VERBOSE) $display("%t Prefetcher backwards table collision or invalid tableTag %h ourTag %h valid %h", $time, bResp.tag, bTag, bResp.valid);
        end
    endrule

    // Prediction table
    (* descending_urgency = "predicitionTableRdReqFromDataArrival, predicitionTableRdReqFromCapSize" *)
     rule predicitionTableRdReqFromCapSize if (initsDone());
        let predRespData = dataForPredRdReqFromCapSize.first;
        dataForPredRdReqFromCapSize.deq;

        dataForPredRdReq.enq(predRespData);
    endrule
    
    // rule predicitionTableRdReqFromShortcut if (initsDone());
    //     let predRespData = dataForPredRdReqFromShortcut.first;
    //     dataForPredRdReqFromShortcut.deq;

    //     dataForPredRdReq.enq(predRespData);
    // endrule

    rule predicitionTableRdReqFromDataArrival if (initsDone());
        let predRespData = dataForPredRdReqFromDataArrival.first;
        dataForPredRdReqFromDataArrival.deq;

        dataForPredRdReq.enq(predRespData);
    endrule

    rule predictionTableReadReq;
        let predRespData = dataForPredRdReq.first;
        dataForPredRdReq.deq;

        predictionTable.rdReq(predRespData.parentPC);
        dataForPredRdResp.enq(predRespData);

        if (`VERBOSE) $display("%t Prefetcher predictionTableReadReq parentPC %h dataForPredRdResp ", $time, predRespData.parentPC, fshow(predRespData));
    endrule

    rule predictionTableReadResp;
        let predRespData = dataForPredRdResp.first;
        dataForPredRdResp.deq;
        
        predictionDepTableRespT predTableResp = predictionTable.rdResp();
        predictionTable.deqResp(predTableResp.hit);
        
        currentPredictionTableResp.enq(predTableResp);
        currentPredictionTableRespData.enq(predRespData);

        if (`VERBOSE) $display("%t Prefetcher predictionTableReadResp response ", $time, predTableResp);

    endrule
    
    rule deqPredRdResp if (!canDoAnyPrefetch);
        $display("%t Prefetcher deqPredRdResp", $time, fshow(currentPredictionTableResp.first), fshow(currentPredictionTableRespData.first), fshow (predRespWaysUsed));
        currentPredictionTableResp.deq;
        currentPredictionTableRespData.deq;
        predRespWaysUsed <= replicate(False);
    endrule

    (* descending_urgency = "deqPredRdResp, processCurrentPredictionTableResp" *)
    rule processCurrentPredictionTableResp;
        if (`VERBOSE) $display("%t Prefetcher processCurrentPredictionTableResp ", $time, fshow(predRespWaysUsed), fshow(currentPredictionTableResp.first), fshow(currentPredictionTableRespData.first));
        
        Vector#(predictionTableWays, predictionWayT) wayVec = genWith(fromInteger);
        let prefetchIdx = findIndex(canPrefetch, wayVec);

        if (prefetchIdx matches tagged Valid .idx) begin
            let predEntry = currentPredictionTableResp.first.entries[idx];
            let predRdRespData = currentPredictionTableRespData.first;

            Vector#(predictionTableWays, Bool) predRespWaysUsedVec = predRespWaysUsed;

            predRespWaysUsedVec[idx] = True;

            // for (Integer i = 0; i < valueof(predictionTableWays); i = i+1) begin
            //     if (currentPredictionTableResp.first.entries[i].childOffset == predEntry.childOffset) begin
            //         predRespWaysUsedVec[i] = True;
            //     end
            // end

            predRespWaysUsed <= predRespWaysUsedVec;

            Addr offset = extend(predEntry.childOffset);
            let cap = setOffset(predRdRespData.filledCap, offset).value;

            if (`VERBOSE) $display("%t Prefetcher processCurrentPredictionTableResp foundPrefetch childOffset %h", $time, predEntry.childOffset);
            
            Addr prefetchAddr = getAddr(cap);

            // if (getLineAddr(prefetchAddr) == predRdRespData.lineAddr) begin
            //     if (`VERBOSE) $display("%t Prefetcher processCurrentPredictionTableResp shortcut lineAddr %h", $time, predRdRespData.lineAddr);

            //     LineMemDataOffset dataSel = getLineMemDataOffset(prefetchAddr);
            //     MemTaggedData current = getTaggedDataAt(predRdRespData.lineWithTags, dataSel);
            //     CapPipe shortcutChildCap = fromMem(unpack(pack(current)));

            //     if (current.tag) begin
            //         if (`VERBOSE) $display("%t Prefetcher processCurrentPredictionTableResp shortcut tag valid shortcutCap ", $time, fshow(shortcutChildCap));
            //         if (predRdRespData.depth <= fromInteger(recursionDepth)) begin

            //             predictionDepReadRespDataT shortcutPredRdRespData;
            //             shortcutPredRdRespData.parentPC = predEntry.childPC; // Chain PCs
            //             shortcutPredRdRespData.depth = predRdRespData.depth + 1; // Should depth be increased
            //             shortcutPredRdRespData.filledCap = shortcutChildCap; // TODO: add check we have permission to access this capability
            //             shortcutPredRdRespData.lineWithTags = predRdRespData.lineWithTags;
            //             shortcutPredRdRespData.lineAddr = predRdRespData.lineAddr;

            //             dataForPredRdReqFromShortcut.enq(shortcutPredRdRespData);
            //             if (`VERBOSE) $display("%t Prefetcher processCurrentPredictionTableResp shortcut submit", $time);

            //         end
            //         else begin
            //             if (`VERBOSE) $display("%t Prefetcher processCurrentPredictionTableResp shortcut skipped due to depth", $time);
            //         end
            //     end 
            //     else begin
            //         if (`VERBOSE) $display("%t Prefetcher processCurrentPredictionTableResp shortcut tag invalid", $time);
            //     end
            // end
            // else begin
                
            // TODO: add permissions check
            TlbInfo tlbInfo;
            tlbInfo.cap = cap;
            tlbInfo.childPC = predEntry.childPC;
            tlbInfo.depth = predRdRespData.depth;

            tlbLookupQueue.enq(tlbInfo);
            // end


            capSizeTableIdxTagT cIdxTag = getCapSizeTableIdxTag(saturating_truncate(getLength(predRdRespData.filledCap)));
            capSizeTableIdxT cIdx = truncate(cIdxTag);
            capSizeTableTagT cTag = truncateLSB(cIdxTag);

            capSizeTableEntryT ce;
            ce.valid = True;
            ce.recentPC = predRdRespData.parentPC;
            ce.tag = cTag;

            capSizeTable.wrReq(cIdx, ce);
            
        end

    endrule

    // // CapSize table
    
    function Bool isCapSizeQIdxValid(capSizeQIdxT idx) =
         !currentCapSizePrefetchQueryUsed[idx] && currentCapSizePrefetchQuery.first[idx].valid;

    function anyCapSizeQElValid();
        Vector#(capSizeQLineNumElements, capSizeQIdxT) idxVec = genWith(fromInteger);

        return any(isCapSizeQIdxValid, idxVec);
    endfunction

    rule deqFromCapSizeQueue(!anyCapSizeQElValid);
        currentCapSizePrefetchQuery.deq;
        currentCapSizePrefetchQueryUsed <= replicate(False);
        if (`VERBOSE) $display("%t Prefetcher deqFromCapSizeQueue ", $time);
    endrule

    rule enqFromCapSizePrefetchQueue; 
        let capSizePrefetchQuery = capSizePrefetchQueryQueue.first;
        capSizePrefetchQueryQueue.deq;

        currentCapSizePrefetchQuery.enq(capSizePrefetchQuery);
        if (`VERBOSE) $display("%t Prefetcher enqFromCapSizePrefetchQueue foundMatch ", $time, fshow(capSizePrefetchQuery));

    endrule

    rule enqPredictionRdFromCapSize;
        let capSizePrefetchQuery = currentCapSizePrefetchQuery.first;

        Vector#(capSizeQLineNumElements, capSizeQIdxT) idxVec = genWith(fromInteger);
        let capSizeQIndex = findIndex(isCapSizeQIdxValid, idxVec);
        if (`VERBOSE) $display("%t Prefetcher enqPredictionRdFromCapSize ", $time, fshow(capSizePrefetchQuery));
        
        if (capSizeQIndex matches tagged Valid .idx) begin
            if (`VERBOSE) $display("%t Prefetcher enqPredictionRdFromCapSize foundMatch ", $time, fshow(capSizePrefetchQuery));

            let capSizeQEl = currentCapSizePrefetchQuery.first[idx]; 

            Vector#(capSizeQLineNumElements, Bool) currentCapSizePrefetchQueryUsedVec = currentCapSizePrefetchQueryUsed;
            let matchedCapSize = getLength(capSizeQEl.cap);
            for (Integer i = 0; i < valueof(capSizeQLineNumElements); i = i+1) begin
                let otherCapSize = getLength(currentCapSizePrefetchQuery.first[i].cap);
                
                if (otherCapSize == matchedCapSize) begin
                    currentCapSizePrefetchQueryUsedVec[i] = True;
                end
            end

            currentCapSizePrefetchQueryUsed <= currentCapSizePrefetchQueryUsedVec;

            capSizeTableIdxTagT capSizeIdxTag = getCapSizeTableIdxTag(saturating_truncate(matchedCapSize));
            capSizeTableIdxT capSizeIdx = truncate(capSizeIdxTag);

            dataForCapSizeRdResp.enq(capSizeQEl);
            capSizeTable.rdReq(capSizeIdx);
        end
    endrule

    rule processCapSizeRdResp;
        let capSizeQEl = dataForCapSizeRdResp.first;
        dataForCapSizeRdResp.deq;

        let capSizeResp = capSizeTable.rdResp();
        capSizeTable.deqRdResp;


        capSizeTableIdxTagT capSizeIdxTag = getCapSizeTableIdxTag(saturating_truncate(getLength(capSizeQEl.cap)));
        capSizeTableTagT capSizeTag = truncateLSB(capSizeIdxTag);

        if (`VERBOSE) $display("%t Prefetcher processCapSizeRdResp: ", $time, fshow(capSizeQEl));


        if (capSizeResp.tag == capSizeTag) begin

            predictionDepReadRespDataT predRdRespData;

            predRdRespData.parentPC = capSizeResp.recentPC;
            predRdRespData.depth = 0;
            predRdRespData.filledCap = capSizeQEl.cap;
            // predRdRespData.lineWithTags = lineWithTags;
            // predRdRespData.lineAddr = getLineAddr(addr);

            dataForPredRdReqFromCapSize.enq(predRdRespData);
            if (`VERBOSE) $display("%t Prefetcher processCapSizeRdResp tag match: ", $time, fshow(capSizeQEl), predRdRespData);

        end
    endrule

    // Tlb

    rule doTlbLookup;
        let tlbInfo = tlbLookupQueue.first;
        tlbLookupQueue.deq;

        toTlb.prefetcherReq(tlbInfo.cap, Valid(PrefetchOtherInfo {depth: tlbInfo.depth, childPC: tlbInfo.childPC}));
        if (`VERBOSE) $display("%t Prefetcher doTlbLookup boundsVirtBase %h boundsOffset %h boundsLength %h depth %d childPC %h", $time, getBase(tlbInfo.cap), getOffset(tlbInfo.cap), getLength(tlbInfo.cap), tlbInfo.depth, tlbInfo.childPC);
    endrule

    rule getTlbResp;
        let resp = toTlb.prefetcherResp;
        toTlb.deqPrefetcherResp;

        if (`VERBOSE) $display("%t Prefetcher got TLB response: ", $time, fshow(resp));

        doAssert(isValid(resp.prefetchOtherInfo), "TLB response should have tagged prefetchOtherInfo");

        if (!resp.haveException && resp.paddr != 0) begin
            prefetchFilterIdxTagT prefetchFilterIdxTag = getPrefetchFilterIdxTag(getLineAddr(resp.paddr));
            prefetchFilterIdxT prefetchFilterIdx = truncate(prefetchFilterIdxTag);

            if (`VERBOSE) $display("%t prefetcher prefetchfilter RdReq prediction idx %h", $time, prefetchFilterIdx);
            prefetchFilterTable.rdReq(prefetchFilterIdx);
            dataForPrefetchFilterRdResp.enq(tuple3(resp.paddr, resp.cap, fromMaybe(?, resp.prefetchOtherInfo)));
        end
    endrule

    // methods

    method Action reportAccess(Addr addr, PCHash pcHash, HitOrMiss hitMiss, MemOp op, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms);
        if (`VERBOSE) $display("%t Prefetcher logReportAccess addr %h pcHash %h hitMiss %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, hitMiss, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, PCHash pcHash, MemOp op, Bool wasMiss, Bool wasPrefetch, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase, Bit#(31) capPerms, Maybe#(PrefetchOtherInfo) prefetchOtherInfo, Bool hitOnPrefetch, Bit#(64) startTime);

        LineMemDataOffset dataSel = getLineMemDataOffset(addr);
        MemTaggedData current = getTaggedDataAt(lineWithTags, dataSel);
        CapPipe selCap = fromMem(unpack(pack(current)));

        if (!wasPrefetch) begin
                // Write new access to backwards table
                if (current.tag && getLength(selCap) <= fromInteger(maxCapSizeForDependence)) begin

                    backwardsTableIdxTagT bIdxTag = getBackwardsIdxTag(getBase(selCap)); // virt base of new child
                    backwardsTableIdxT bIdx = truncate(bIdxTag);
                    backwardsTableTagT bTag = truncateLSB(bIdxTag);

                    backwardsTableEntryT be;
                    be.valid = True;
                    be.parentPC = pcHash;
                    be.tag = bTag;

                    backwardsEntryToWrite.enq(tuple2(bIdx, be));
                    if (`VERBOSE) $display("%t Prefetcher backwardsEntryToWrite enq idx %h entry ", $time, bIdx, fshow(be));
                end


                // Update prediction table based on access
                // First needs to read from backwards table to find parent
                if (boundsLength <= fromInteger(maxCapSizeForDependence)) begin
                    backwardsTableIdxTagT bIdxTag = getBackwardsIdxTag(boundsVirtBase); // virt base of old child for lookup
                    backwardsTableIdxT bIdx = truncate(bIdxTag);
                    backwardsTableTagT bTag = truncateLSB(bIdxTag);

                    backwardsDepReadRespDataT backwardsRespData;
                    backwardsRespData.bIdxTag = bIdxTag;
                    backwardsRespData.childOffset = boundsOffset;
                    backwardsRespData.childPC = pcHash;

                    dataForBtReadReq.enq(backwardsRespData);
                    if (`VERBOSE) $display("%t Prefetcher dataForBtReadReq enq", $time,fshow(backwardsRespData));
                end
        end

        // Read from prediction table as can now chain next prefetch
        depthT newDepth = 0;

        if (current.tag && getLength(selCap) <= fromInteger(maxCapSizeForDependence)) begin
            if (wasPrefetch) begin
                if (prefetchOtherInfo matches tagged Valid .prefetchInfo) begin
                    if (prefetchInfo.depth <= fromInteger(recursionDepth)) begin
                        predictionDepReadRespDataT predRdRespData;
                        
                        predRdRespData.parentPC = prefetchInfo.childPC; // Chain PCs
                        predRdRespData.depth = prefetchInfo.depth + 1;
                        predRdRespData.filledCap = selCap;
                        // predRdRespData.lineWithTags = lineWithTags;
                        // predRdRespData.lineAddr = getLineAddr(addr);

                        dataForPredRdReqFromDataArrival.enq(predRdRespData);
                        if (`VERBOSE) $display("%t Prefetcher dataForPredRdReq enq chain", $time,fshow(predRdRespData));

                    end
                end
            end 
            else begin
                predictionDepReadRespDataT predRdRespData;

                predRdRespData.parentPC = pcHash;
                predRdRespData.depth = 0;
                predRdRespData.filledCap = selCap;
                // predRdRespData.lineWithTags = lineWithTags;
                // predRdRespData.lineAddr = getLineAddr(addr);
                
                dataForPredRdReqFromDataArrival.enq(predRdRespData);
                if (`VERBOSE) $display("%t Prefetcher dataForPredRdReq enq", $time,fshow(predRdRespData));

            end
        end

        Vector#(4, CapSizePrefetchQuery) capSizeQueries;
        Bool foundAnyCaps = False;

        // TODO: Can be optimised to only three elements as ignoring sel cap
        for (Integer i = 0; i < 4; i = i + 1) begin
            MemTaggedData d = getTaggedDataAt(lineWithTags, fromInteger(i));
            CapPipe cap = fromMem(unpack(pack(d)));

            CapSizePrefetchQuery capSizePrefetchQuery;
            capSizePrefetchQuery.valid = d.tag && fromInteger(i) == dataSel;
            capSizePrefetchQuery.cap = cap;

            capSizeQueries[i] = capSizePrefetchQuery;

            foundAnyCaps = foundAnyCaps || d.tag;
        end
        if (foundAnyCaps) begin
            capSizePrefetchQueryQueue.enq(capSizeQueries);
            if (`VERBOSE) $display("$t Prefetcher reportDataArrival capSizePrefetchQuery enqueued ", fshow(capSizeQueries));
        end

        if (`VERBOSE) begin

            MemTaggedData d1 = getTaggedDataAt(lineWithTags, 0);
            MemTaggedData d2 = getTaggedDataAt(lineWithTags, 1);
            MemTaggedData d3 = getTaggedDataAt(lineWithTags, 2);
            MemTaggedData d4 = getTaggedDataAt(lineWithTags, 3);

            CapPipe cap1 = fromMem(unpack(pack(d1)));
            CapPipe cap2 = fromMem(unpack(pack(d2)));
            CapPipe cap3 = fromMem(unpack(pack(d3)));
            CapPipe cap4 = fromMem(unpack(pack(d4)));

            $display("%t Prefetcher logReportDataArrival requestAddr %h pcHash %h wasMiss %b wasPrefetch %b boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h op %h", $time, addr, pcHash, wasMiss, wasPrefetch, boundsOffset, boundsLength, boundsVirtBase, capPerms, op);
            $display("%t Preftecher logReportDataArrivalCap capIndex 1 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d1.tag, getAddr(cap1), getOffset(cap1), getLength(cap1), getBase(cap1), getPerms(cap1));
            $display("%t Preftecher logReportDataArrivalCap capIndex 2 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d2.tag, getAddr(cap2), getOffset(cap2), getLength(cap2), getBase(cap2), getPerms(cap2));
            $display("%t Preftecher logReportDataArrivalCap capIndex 3 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d3.tag, getAddr(cap3), getOffset(cap3), getLength(cap3), getBase(cap3), getPerms(cap3));
            $display("%t Preftecher logReportDataArrivalCap capIndex 4 tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, d4.tag, getAddr(cap4), getOffset(cap4), getLength(cap4), getBase(cap4), getPerms(cap4));
            $display("%t Preftecher logReportDataArrivalSelectedCap capIndex %b tag %b addr %h boundsOffset %h boundsLength %h boundsVirtBase %h capPerms %h", $time, dataSel, current.tag, getAddr(selCap), getOffset(selCap), getLength(selCap), getBase(selCap), getPerms(selCap));
        end
    endmethod

    method ActionValue#(Tuple3#(Addr, CapPipe, PrefetchOtherInfo)) getNextPrefetchAddr;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, tpl_1(prefetchQueue.first));
        prefetchQueue.deq;

        return prefetchQueue.first;
    endmethod

    method Action reportCacheEviction(LineAddr lineAddr);
        if (`VERBOSE) $display("%t Prefetch logCacheEviction lineAddr %h", lineAddr);
        evictFromPrefetchFilterQ.enq(lineAddr);
    endmethod
endmodule
`endif