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

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, Bit#(16) pcHash, Bool wasPrefetch, Addr boundsOffset, Addr boundsLength, 
        Addr boundsVirtBase);
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

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, Bit#(16) pcHash, Bool wasPrefetch, Addr boundsOffset, Addr boundsLength, 
        Addr boundsVirtBase);
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

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
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

    method Action reportCacheDataArrival(CLine lineWithTags, Addr accessAddr, Bit#(16) pcHash, Bool wasPrefetch, Addr boundsOffset, Addr boundsLength, 
        Addr boundsVirtBase);
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
    Fifo#(pfQueueSize, LineAddr) pfQueue <- mkOverflowPipelineFifo;
    Fifo#(1, Tuple8#(Addr, HitOrMiss, LineAddr, Bool, Bool, bitmapTableIdxT, filterTableIdxTagT, Addr)) dataForRdResp <- mkPipelineFifo;
    Fifo#(1, Bit#(7)) dataForRdResp2 <- mkPipelineFifo;
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
        
        Vector#(128, LineState) bitmap = append(bt.rdResp[0].bitmap, bt.rdResp[1].bitmap);
        //if (`VERBOSE) $display("%t prefetcher:processRdResp bitmap: ", $time, fshow(bitmap));
        bt.deqRdResp;
        filterEntryT fte = ft.rdResp;
        ft.deqRdResp;
        let {accessAddr, hitMiss, boundsOffset2, ignoreFirstPage, ignoreSecondPage, btIdx, ftIdxTag, boundsLength} = dataForRdResp.first;
        Bit#(7) accessIdx = dataForRdResp2.first;
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
            
            if (`VERBOSE) $display("%t prefetcher:processRdResp MISS offset %h in new cap %h (for cap idx %h), found %d possible prefetches!", 
                $time, boundsOffset2, ftIdxTag, btIdx, countElem(True, canPrefetchVec));
            //if (`VERBOSE) $display("%t prefetcher:processRdResp canPrefetchVec: ", 
                //$time, fshow(canPrefetchVec));

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
            if (`VERBOSE) $display("%t -- prefetcher:issuePrefetches %h", $time, Addr'{toPrefetch, '0});
            pfQueue.enq(extend(toPrefetch));

            EventsPrefetcher evt = unpack(0);
            evt.evt_4 = 1;
            perf_events[3] <= evt;
        end
        
    endrule

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
        if (boundsLength > 64 && boundsLength <= fromInteger(valueOf(maxCapSizeToTrack))) begin
            //$display("%t prefetcher:reportAccess %h with bounds length %d base %h offset %d", $time, addr, boundsLength, boundsVirtBase, boundsOffset);
            //Not all objects are aligned in the same way, so we separate the training bitmaps for objects that are aligned differently
            //Otherwise, one 8-byte field in different objects might land in 2 different cache lines, 
            //meaning both cache lines would be prefetched every time.
            //As this reduces the amount of training data, this is done partially, grouping objects with same 16byte alignment together
            Bit#(2) capStart16byteOffset = boundsVirtBase[5:4]; 
            Bit#(6) offsetInLine = truncate(boundsVirtBase);
            pageAddressT pa = truncateLSB(addr);
            Bit#(6) accessLineInPage = addr[11:6];
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
            Bit#(TSub#(TLog#(bitmapTableSize), 1)) ogHash = (hash(boundsLength) ^ extend(capStart16byteOffset));
            bitmapTableIdxT bidx =       {ogHash, 1'b0} + signExtend(cacheLineGroupPageStart);
            bitmapTableIdxT write_bidx = {ogHash, 1'b0} + signExtend(cacheLineGroup);
            doAssert(bidx == write_bidx || bidx + 1 == write_bidx, "");
            bt.rdReq(bidx);
            filterTableIdxTagT fidx = hash(boundsVirtBase) ^ hash(pa);
            ft.rdReq(truncate(fidx));
            $display("%t -- prefetcher:reportAccess %h boundslength %d boundsoffset2 %h ignorefirstp %d ignroesecondp %d readbidx %h write_bidx %h accessidxbitmap %d oghash %h clinegroup %d clinepagest %d",
             $time, addr, boundsLength, boundsOffset2, ignoreFirstPage, ignoreSecondPage, bidx, write_bidx, accessIdxInBitmap, ogHash, cacheLineGroup, cacheLineGroupPageStart);
            dataForRdResp.enq(tuple8(addr, hitMiss, boundsOffset2, ignoreFirstPage, ignoreSecondPage, write_bidx, fidx, boundsLength));
            dataForRdResp2.enq(accessIdxInBitmap);
        end
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
        pfQueue.deq;
        return {pfQueue.first, '0};
    endmethod
    method Action reportCacheDataArrival(CLine lineWithTags, Addr accessAddr, Bit#(16) pcHash, Bool wasPrefetch, Addr boundsOffset, Addr boundsLength, 
        Addr boundsVirtBase);
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
} PtrTableEntry #(numeric type tagBits) deriving (Bits, Eq, FShow);

//Indexed by virtual address
typedef struct {
    Bit#(tagBits) tag;
    Bit#(ptrTableIdxTagBits) ptrTableIdxTag;
} TrainingTableEntry#(numeric type tagBits, numeric type ptrTableIdxTagBits) deriving (Bits, Eq, FShow);

module mkCapPtrPrefetcher#(Parameter#(ptrTableSize) _, Parameter#(trainingTableSize) __, Parameter#(inverseDecayChance) ___)(CheriPCPrefetcher) provisos (
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
    Alias#(potentialPrefetchT, Tuple2#(ptrTableIdxTagT, Addr)),

    Add#(a__, 60, TMul#(TDiv#(60, TAdd#(TLog#(ptrTableSize), 16)), TAdd#(TLog#(ptrTableSize), 16))),
    Add#(1, b__, TDiv#(64, TAdd#(TLog#(ptrTableSize), 16))),
    Add#(c__, TAdd#(TLog#(trainingTableSize), 16), 64),
    Add#(1, d__, TDiv#(64, TAdd#(TLog#(trainingTableSize), 16))),
    Add#(e__, 64, TMul#(TDiv#(64, TAdd#(TLog#(trainingTableSize), 16)), TAdd#(TLog#(trainingTableSize), 16))),
    Add#(f__, 64, TMul#(TDiv#(64, TAdd#(TLog#(ptrTableSize), 16)), TAdd#(TLog#(ptrTableSize), 16))),
    Add#(1, g__, TDiv#(60, TAdd#(TLog#(ptrTableSize), 16)))

);
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (4, unpack (0));
    RWBramCore#(ptrTableIdxT, ptrTableEntryT) pt <- mkRWBramCoreForwarded();
    RWBramCore#(trainingTableIdxT, trainingTableEntryT) tt <- mkRWBramCoreForwarded();
    Fifo#(1, trainingTableTagT) dataForTtRead <- mkPipelineFifo;
    Fifo#(8, ptrTableIdxTagT) ptUpgradeQueue <- mkOverflowBypassFifo;
    Fifo#(1, ptrTableIdxTagT) ptUpgradeQueueReading <- mkPipelineFifo;

    Fifo#(4, Vector#(4, Maybe#(potentialPrefetchT))) ptLookupQueueWide <- mkOverflowBypassFifo;
    Reg#(Vector#(4, Maybe#(potentialPrefetchT))) currPit <- mkReg(replicate(Invalid));
    Fifo#(8, potentialPrefetchT) ptLookupQueue <- mkOverflowBypassFifo;
    Fifo#(1, potentialPrefetchT) ptLookupQueueReading <- mkPipelineFifo;

    Fifo#(4, Addr) prefetchQueue <- mkOverflowPipelineFifo;
    Reg#(Bit#(8)) randomCounter <- mkConfigReg(0);

    
    function ptrTableIdxTagT getIdxTag(Addr boundsLength, Addr boundsOffset) =
        //boundsOffset should be an offset of a cap, so 16 byte aligned, so drop its lowest 4 bits
         hash(boundsLength) ^ hash(boundsOffset[63:4]);

    function trainingTableIdxTagT getTrainingIdxTag(Addr vaddr) =
        //vaddr is a pointer and is kinda often 16 byte aligned, so rearrange for better LSBs (for index).
         hash({vaddr[3:0], vaddr[63:4]});

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

    rule processTtRead;
        dataForTtRead.deq;
        let tTag = dataForTtRead.first;
        tt.deqRdResp;
        let te = tt.rdResp;
        if (te.tag == tTag) begin
            //Match -- upgrade ptrTable
            if (`VERBOSE) $display("%t Prefetcher training table match! Will upgrade ptr table pit %h", $time, te.ptrTableIdxTag);
            ptUpgradeQueue.enq(te.ptrTableIdxTag);
        end
        else begin
            if (`VERBOSE) $display("%t Prefetcher training table mismatch! table %h now %h", $time, te.tag, tTag);
        end
    endrule

    (* descending_urgency = "doPtReadForUpgrade, doPtReadForLookup" *)
    rule doPtReadForUpgrade;
        let pit = ptUpgradeQueue.first;
        ptUpgradeQueue.deq;
        ptUpgradeQueueReading.enq(pit);
        pt.rdReq(truncate(pit));
    endrule

    (* descending_urgency = "processPtReadUpgrade, processPtReadForLookup" *)
    rule processPtReadUpgrade;
        let pte = pt.rdResp;
        pt.deqRdResp;
        let pit = ptUpgradeQueueReading.first;
        ptUpgradeQueueReading.deq;
        if (pte.tag == truncateLSB(pit)) begin
            pte.state = upgrade(pte.state);
            if (`VERBOSE) $display("%t Prefetcher processPtReadUpgrade upgrading pit %h to ", $time, pit, fshow(pte.state));
        end
        else begin
            pte.state = USED1;
            pte.tag = truncateLSB(pit);
            if (`VERBOSE) $display("%t Prefetcher processPtReadUpgrade tag mismatch reset pit %h entry to ", $time, pit, fshow(pte.state));
        end
        pt.wrReq(truncate(pit), pte);
    endrule

    rule serializePtLookupEnq if (countIf(isValid, currPit) > 0);
        let currPitVec = currPit;
        let midx = findIndex(isValid, currPitVec);
        if (midx matches tagged Valid .idx &&& currPit[idx] matches tagged Valid .pp) begin
            ptLookupQueue.enq(pp);
            $display("%t serializer enq ", $time, fshow(pp));
            currPitVec[idx] = Invalid;
        end
        currPit <= currPitVec;
    endrule

    rule serializePtLookupNew if (countIf(isValid, currPit) == 0);
        let currPitVec = currPit;
        $display("%t serializer getting new queue entry", $time);
        currPitVec = ptLookupQueueWide.first;   
        ptLookupQueueWide.deq;
        currPit <= currPitVec;
    endrule

    (* descending_urgency = "doPtReadForUpgrade, doPtReadForLookup" *)
    rule doPtReadForLookup;
        let {pit, addr} = ptLookupQueue.first;
        ptLookupQueue.deq;
        ptLookupQueueReading.enq(tuple2(pit, addr));
        pt.rdReq(truncate(pit));
    endrule

    (* descending_urgency = "processPtReadUpgrade, processPtReadForLookup" *)
    rule processPtReadForLookup;
        //downgrade pte with some chance
        let {pit, addr} = ptLookupQueueReading.first;
        ptLookupQueueReading.deq;
        let pte = pt.rdResp;
        pt.deqRdResp;
        if (`VERBOSE) $display("%t Prefetcher processPtReadForLookup pit %h table tag %h read tag %h addr %h", $time, pit, pte.tag, ptrTableTagT'{truncateLSB(pit)}, addr);
        if (pte.tag == truncateLSB(pit)) begin
            if (`VERBOSE) $display("%t Prefetcher processPtReadForLookup tag match", $time, fshow(pte.state));
            if (pte.state == USED2 || pte.state == USED3) begin
                prefetchQueue.enq(addr);
            end
            if (randomCounter == 0) begin
                pte.state = downgrade(pte.state);
                if (`VERBOSE) $display("%t Prefetcher processPtReadForLookup %h downgrading to ", $time, pit, fshow(pte.state));
            end
        end
        pt.wrReq(truncate(pit), pte);
    endrule

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
        //Lookup addr in training table, if get a hit, update ptrTable
        Addr vaddr = boundsVirtBase + boundsOffset;
        trainingTableIdxTagT tit = getTrainingIdxTag(vaddr);
        if (`VERBOSE) $display("%t Prefetcher reportAccess %h boundslen %d tit %h", $time, addr, boundsLength, tit, fshow(hitMiss));
        dataForTtRead.enq(truncateLSB(tit));
        tt.rdReq(truncate(tit));
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, Bit#(16) pcHash, Bool wasPrefetch, Addr boundsOffset, Addr boundsLength, 
        Addr boundsVirtBase);

        //Add accessed cap to training table in case we dereference it later.
        if (addr[3:0] == 0) begin
            //addr targeted a multiple of 16 bytes -- so potentially a capability
            let offset = getLineMemDataOffset(addr);
            MemTaggedData d = getTaggedDataAt(lineWithTags, offset);
            CapPipe cap = fromMem(unpack(pack(d)));
            if (d.tag) begin
                //install ptr addr of cap in training table
                ptrTableIdxTagT pit = getIdxTag(boundsLength, boundsOffset);
                trainingTableIdxTagT tit = getTrainingIdxTag(getAddr(cap));
                trainingTableTagT tTag = truncateLSB(tit);
                trainingTableIdxT tIdx = truncate(tit);
                trainingTableEntryT te;
                if (`VERBOSE) $display("%t Prefetcher reportDataArrival adding training table entry! access addr %h boundslen %d prefetch %b ptraddress %h tit %h pit %h", 
                    $time, addr, boundsLength, wasPrefetch, getAddr(cap), tit, pit);
                te.tag = tTag;
                te.ptrTableIdxTag = pit;
                tt.wrReq(tIdx, te);
            end
        end

        //Queue caps here for lookup in ptr table
        Vector#(4, Maybe#(potentialPrefetchT)) v = replicate(Invalid);
        for (Integer i = 0; i < 4; i = i + 1) begin
            MemTaggedData d = getTaggedDataAt(lineWithTags, fromInteger(i));
            CapPipe cap = fromMem(unpack(pack(d)));
            Addr clineStartOffset = (boundsOffset-extend(addr[5:0]));
            ptrTableIdxTagT pit = getIdxTag(boundsLength, clineStartOffset+fromInteger(i)*16);
            $display("preftcher lookup clinestart offset %h pit %h", clineStartOffset, pit);
            if (d.tag) begin
                v[i] = Valid(tuple2(pit, getAddr(cap)));
            end
        end
        if (v != replicate(Invalid)) begin
            if (`VERBOSE) $display("%t Prefetcher reportDataArrival addr %h prefetech %b adding %d caps for prefetch lookups ", 
                $time, addr, wasPrefetch, countElem(True, map(isValid, v)), fshow(v));
            ptLookupQueueWide.enq(v);
        end
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time, prefetchQueue.first);
        prefetchQueue.deq;
        return prefetchQueue.first;
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return  unpack(0);
    endmethod
`endif

endmodule


module mkCapPtrTestPrefetcher(CheriPCPrefetcher) provisos ();
    Fifo#(4, Addr) prefetchRq <- mkOverflowPipelineFifo;
    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, 
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
        if (`VERBOSE) $display("%t Prefetcher reportAccess %h boundslen %d", $time, addr, boundsLength, fshow(hitMiss));
    endmethod

    method Action reportCacheDataArrival(CLine lineWithTags, Addr addr, Bit#(16) pcHash, Bool wasPrefetch, Addr boundsOffset, Addr boundsLength, 
        Addr boundsVirtBase);
        MemTaggedData d = getTaggedDataAt(lineWithTags, 0);
        CapPipe cap = fromMem(unpack(pack(d)));
        if (d.tag) begin
            prefetchRq.enq(getAddr(cap));
            if (`VERBOSE) $display("%t Prefetcher reportDataArrival CapPipe ", $time, fshow(cap));
        end
        if (`VERBOSE) $display("%t Prefetcher reportDataArrival %h boundslen %d prefetch %b", $time, addr, boundsLength, wasPrefetch, fshow(lineWithTags));
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
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
