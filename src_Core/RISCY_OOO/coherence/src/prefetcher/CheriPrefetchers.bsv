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
import ConfigReg::*;
import SpecialRegs::*;

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
    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
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
    method ActionValue#(Addr) getNextPrefetchAddr 
        if (prefetchNext <= prefetchEnd && prefetchNext != originalMiss);
        
        prefetchNext <= prefetchNext + 1;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time,Addr'{prefetchNext, '0});
        return Addr'{prefetchNext, '0};

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
module mkCheriStridePrefetcher#(Parameter#(strideTableSize) _, Parameter#(cLinesAheadToPrefetch) __)(CheriPCPrefetcher)
provisos(
    Alias#(strideTableIndexT, Bit#(TLog#(strideTableSize))),
    Add#(a__, TLog#(strideTableSize), 16)
    );
    RWBramCore#(strideTableIndexT, StrideEntry) strideTable <- mkRWBramCoreForwarded;
    FIFOF#(Tuple5#(Addr, Bit#(16), HitOrMiss, Addr, Addr)) memAccesses <- mkSizedBypassFIFOF(16);
    Reg#(Tuple5#(Addr, Bit#(16), HitOrMiss, Addr, Addr)) rdRespEntry <- mkReg(?);

    Fifo#(8, Addr) addrToPrefetch <- mkOverflowPipelineFifo;
    FIFO#(Tuple5#(StrideEntry, Addr, Bit#(16), Addr, Addr)) strideEntryForPrefetch <- mkBypassFIFO();
    Reg#(Maybe#(Bit#(4))) cLinesPrefetchedLatest <- mkReg(?);
    PulseWire holdReadReq <- mkPulseWire;
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (3, unpack (0));

    rule sendReadReq if (!holdReadReq);
        match {.addr, .boundsHash, .hitMiss, .bot, .top} = memAccesses.first;
        if (`VERBOSE) $display("%t Sending read req for %h!", $time, boundsHash);
        strideTable.rdReq(truncate(boundsHash));
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
        strideTableIndexT index = truncate(boundsHash);
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
            True /*isInCapBounds*/
        ) begin
            //can prefetch

            addrToPrefetch.enq(reqAddr);
            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = (bot+top >= 4096) ? 1 : 0;
            evt.evt_2 = 1;
            if (isInCapBounds) begin
                evt.evt_3 = 1;
            end
            perf_events[0] <= evt;
            // We will still be processing this StrideEntry next cycle, 
            // so hold off any potential read requests until we do a writeback
            holdReadReq.send();
            cLinesPrefetchedLatest <= Valid(cLinesPrefetched + 1);
            if (`VERBOSE) $display("%t Stride Prefetcher getNextPrefetchAddr requesting %h for entry %h", $time, reqAddr, boundsHash[7:0]);
        end
        else begin
            //cant prefetch
            if (`VERBOSE) $display("%t Stride Prefetcher no possible prefetch for entry %h", $time, strideTableIndexT'(truncate(boundsHash)));
            strideEntryForPrefetch.deq;
            se.cLinesPrefetched = cLinesPrefetched;
            cLinesPrefetchedLatest <= Invalid;
            strideTable.wrReq(truncate(boundsHash), se);
        end
    endrule

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
        Bit#(16) lenHash = hash(boundsLength);
        Bit#(16) boundsHash = pcHash;
        Addr topCapGap = (boundsLength == 0) ? -1 : boundsLength-boundsOffset-1;
        EventsPrefetcher evt = unpack(0);
        if (boundsLength == 0) begin
            evt.evt_1 = 1;
        end
        perf_events[1] <= evt;
        //Bit#(8) boundsHash = hash(boundsVirtBase ^ boundsLength) ^ pcHash[7:0] ^ pcHash[15:8];
        //if (boundsHash == 0)
            //hashIsSmall.send();
        if (`VERBOSE) $display("%t Prefetcher reportAccess %h %h, hash: %h", $time, boundsLength, boundsVirtBase, boundsHash);
        memAccesses.enq(tuple5 (addr, boundsHash, hitMiss, boundsOffset, topCapGap));
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
        EventsPrefetcher evt = unpack(0);
        evt.evt_4 = 1;
        perf_events[2] <= evt;
        addrToPrefetch.deq;
        return addrToPrefetch.first;
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
  NOTUSED = 2'd0, USED1 = 2'd1, USED2 = 2'd2, USED3 = 2'd3
} LineState deriving (Bits, Eq, FShow);

typedef struct {
    Vector#(numEntries, LineState) bitmap;
} BitmapEntry#(numeric type numEntries) deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(tagBits) tag;
    Bool prefetched;
} FilterEntry#(numeric type tagBits) deriving (Bits, Eq, FShow);

module mkCapBitmapPrefetcher#(Parameter#(maxCapSizeToTrack) _, Parameter#(bitmapTableSize) __, 
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
    Add#(1, i__, TDiv#(16, TLog#(bitmapTableSize)))

);
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (4, unpack (0));
    RWBramCore#(bitmapTableIdxT, bitmapEntryT) bt <- mkRWBramCoreForwarded();
    RWBramCore#(filterTableIdxT, filterEntryT) ft <- mkRWBramCoreForwarded();
    Fifo#(pfQueueSize, LineAddr) pfQueue <- mkOverflowPipelineFifo;
    Fifo#(1, Tuple7#(Addr, HitOrMiss, LineAddr, Addr, bitmapTableIdxT, filterTableIdxTagT, Addr)) dataForRdResp <- mkPipelineFifo;
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
                if (fromInteger(i) + pageStartCapOffset >= 0 && fromInteger(i) + pageStartCapOffset < fromInteger(valueof(bitmapLength))) begin
                    LineState st = bte.bitmap[fromInteger(i)+pageStartCapOffset];
                    canPrefetchVec[i] = st == USED3 || st == USED2;
                    atLeastUsed2[i] = st == USED1 || st == USED2 || st == USED3;
                end
            end
            if (`VERBOSE) $display("%t prefetcher:processRdResp MISS offset %h in new cap %h (for cap idx %h), found %d possible prefetches!", 
                $time, boundsOffset, ftIdxTag, btIdx, countElem(True, canPrefetchVec));
            if (`VERBOSE) $display("%t prefetcher:processRdResp canPrefetchVec: ", 
                $time, fshow(canPrefetchVec));

            canPrefetch <= canPrefetchVec;
            dataForIssuePrefetches <= tuple2(pa, unpack(truncate(accessLineAddr - pageStartAddr)));

            EventsPrefetcher evt = unpack(0);
            evt.evt_0 = 1;
            evt.evt_1 = (boundsLength <= 256) ? 0 : extend(pack(countElem(True, canPrefetchVec)));
            //evt.evt_1 = extend(pack(countElem(True, atLeastUsed2)));
            evt.evt_2 = (boundsLength <= 256) ? 0 : 1; 
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

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
        if (boundsLength > 64 && boundsLength <= fromInteger(valueOf(maxCapSizeToTrack))) begin
            $display("%t prefetcher:reportAccess %h with bounds length %d base %h offset %d", $time, addr, boundsLength, boundsVirtBase, boundsOffset);
            bitmapTableIdxT bidx = hash(boundsLength);
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

    method ActionValue#(Addr) getNextPrefetchAddr;
        pfQueue.deq;
        return {pfQueue.first, '0};
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
