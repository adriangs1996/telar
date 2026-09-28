/* touchrange: records which bytes of registered ranges a window of the
   client reads or writes. Replaces lackey's main so it builds in place.

   Client requests (tool base 'T','R'):
     TR+0 RANGE(id, base, len)   register a range
     TR+1 START()                clear bitmaps, start recording
     TR+2 STOP(label)            stop and print touched runs per range

   Output lines (to the log):
     TR window <label>
     TR run <range id> <offset> <len> <r|w|rw>
     TR end <label>
*/
#include "pub_tool_basics.h"
#include "pub_tool_tooliface.h"
#include "pub_tool_libcassert.h"
#include "pub_tool_libcprint.h"
#include "pub_tool_libcbase.h"
#include "pub_tool_mallocfree.h"
#include "pub_tool_machine.h"
#include "valgrind.h"

#define TR_BASE VG_USERREQ_TOOL_BASE('T', 'R')
#define TR_RANGE (TR_BASE + 0)
#define TR_START (TR_BASE + 1)
#define TR_STOP (TR_BASE + 2)
#define MAX_RANGES 16

typedef struct {
   UWord id;
   Addr base;
   SizeT len;
   UChar* bits; /* bit 0 read, bit 1 write */
} Range;

static Range ranges[MAX_RANGES];
static Int n_ranges = 0;
static volatile Bool tracing = False;

static void mark(Addr addr, SizeT size, UChar kind)
{
   Int i;
   for (i = 0; i < n_ranges; i++) {
      Range* r = &ranges[i];
      Addr lo, hi, a;
      if (addr >= r->base + r->len || addr + size <= r->base) continue;
      lo = addr < r->base ? r->base : addr;
      hi = addr + size > r->base + r->len ? r->base + r->len : addr + size;
      for (a = lo; a < hi; a++) r->bits[a - r->base] |= kind;
   }
}

static VG_REGPARM(2) void trace_load(Addr addr, SizeT size)
{
   if (tracing) mark(addr, size, 1);
}

static VG_REGPARM(2) void trace_store(Addr addr, SizeT size)
{
   if (tracing) mark(addr, size, 2);
}

static void add_call(IRSB* sb, Bool store, IRExpr* addr, Int size, IRExpr* guard)
{
   IRExpr** argv = mkIRExprVec_2(addr, mkIRExpr_HWord(size));
   IRDirty* di = store
      ? unsafeIRDirty_0_N(2, "trace_store", VG_(fnptr_to_fnentry)(trace_store), argv)
      : unsafeIRDirty_0_N(2, "trace_load", VG_(fnptr_to_fnentry)(trace_load), argv);
   if (guard) di->guard = guard;
   addStmtToIRSB(sb, IRStmt_Dirty(di));
}

static void tr_post_clo_init(void) {}

static IRSB* tr_instrument(VgCallbackClosure* closure, IRSB* sbIn, const VexGuestLayout* layout,
                           const VexGuestExtents* vge, const VexArchInfo* archinfo_host,
                           IRType gWordTy, IRType hWordTy)
{
   Int i;
   IRSB* sbOut = deepCopyIRSBExceptStmts(sbIn);
   IRTypeEnv* tyenv = sbIn->tyenv;

   for (i = 0; i < sbIn->stmts_used; i++) {
      IRStmt* st = sbIn->stmts[i];
      if (!st) continue;
      switch (st->tag) {
         case Ist_WrTmp: {
            IRExpr* data = st->Ist.WrTmp.data;
            if (data->tag == Iex_Load) {
               add_call(sbOut, False, data->Iex.Load.addr, sizeofIRType(data->Iex.Load.ty), NULL);
            }
            break;
         }
         case Ist_Store: {
            IRType type = typeOfIRExpr(tyenv, st->Ist.Store.data);
            add_call(sbOut, True, st->Ist.Store.addr, sizeofIRType(type), NULL);
            break;
         }
         case Ist_StoreG: {
            IRStoreG* sg = st->Ist.StoreG.details;
            IRType type = typeOfIRExpr(tyenv, sg->data);
            add_call(sbOut, True, sg->addr, sizeofIRType(type), sg->guard);
            break;
         }
         case Ist_LoadG: {
            IRLoadG* lg = st->Ist.LoadG.details;
            IRType type = Ity_INVALID, wide = Ity_INVALID;
            typeOfIRLoadGOp(lg->cvt, &wide, &type);
            add_call(sbOut, False, lg->addr, sizeofIRType(type), lg->guard);
            break;
         }
         case Ist_Dirty: {
            IRDirty* d = st->Ist.Dirty.details;
            if (d->mFx == Ifx_Read || d->mFx == Ifx_Modify) add_call(sbOut, False, d->mAddr, d->mSize, NULL);
            if (d->mFx == Ifx_Write || d->mFx == Ifx_Modify) add_call(sbOut, True, d->mAddr, d->mSize, NULL);
            break;
         }
         case Ist_CAS: {
            IRCAS* cas = st->Ist.CAS.details;
            Int size = sizeofIRType(typeOfIRExpr(tyenv, cas->dataLo));
            if (cas->dataHi) size *= 2;
            add_call(sbOut, False, cas->addr, size, NULL);
            add_call(sbOut, True, cas->addr, size, NULL);
            break;
         }
         case Ist_LLSC: {
            if (st->Ist.LLSC.storedata == NULL) {
               add_call(sbOut, False, st->Ist.LLSC.addr, sizeofIRType(typeOfIRTemp(tyenv, st->Ist.LLSC.result)), NULL);
            } else {
               add_call(sbOut, True, st->Ist.LLSC.addr, sizeofIRType(typeOfIRExpr(tyenv, st->Ist.LLSC.storedata)), NULL);
            }
            break;
         }
         default:
            break;
      }
      addStmtToIRSB(sbOut, st);
   }

   return sbOut;
}

static void dump(const HChar* label)
{
   Int i;
   VG_(umsg)("TR window %s\n", label);
   for (i = 0; i < n_ranges; i++) {
      Range* r = &ranges[i];
      SizeT off = 0;
      while (off < r->len) {
         UChar kind = r->bits[off];
         SizeT start = off;
         if (kind == 0) { off++; continue; }
         while (off < r->len && r->bits[off] == kind) off++;
         VG_(umsg)("TR run %lu %lu %lu %s\n", r->id, start, off - start,
                   kind == 1 ? "r" : kind == 2 ? "w" : "rw");
      }
   }
   VG_(umsg)("TR end %s\n", label);
}

static Bool tr_handle_client_request(ThreadId tid, UWord* arg, UWord* ret)
{
   Int i;
   if (!VG_IS_TOOL_USERREQ('T', 'R', arg[0])) return False;
   switch (arg[0]) {
      case TR_RANGE:
         tl_assert(n_ranges < MAX_RANGES);
         ranges[n_ranges].id = arg[1];
         ranges[n_ranges].base = arg[2];
         ranges[n_ranges].len = arg[3];
         ranges[n_ranges].bits = VG_(calloc)("tr.bits", arg[3], 1);
         n_ranges++;
         break;
      case TR_START:
         for (i = 0; i < n_ranges; i++) VG_(memset)(ranges[i].bits, 0, ranges[i].len);
         tracing = True;
         break;
      case TR_STOP:
         tracing = False;
         dump((const HChar*)arg[1]);
         break;
      default:
         return False;
   }
   *ret = 0;
   return True;
}

static void tr_fini(Int exitcode) {}

static void tr_pre_clo_init(void)
{
   VG_(details_name)("touchrange");
   VG_(details_version)(NULL);
   VG_(details_description)("bytes of registered ranges touched per window");
   VG_(details_copyright_author)("telar perf pass");
   VG_(details_bug_reports_to)(VG_BUGS_TO);
   VG_(details_avg_translation_sizeB)(400);
   VG_(basic_tool_funcs)(tr_post_clo_init, tr_instrument, tr_fini);
   VG_(needs_client_requests)(tr_handle_client_request);
}

VG_DETERMINE_INTERFACE_VERSION(tr_pre_clo_init)
