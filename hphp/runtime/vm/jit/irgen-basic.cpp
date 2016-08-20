/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-2016 Facebook, Inc. (http://www.facebook.com)     |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
*/

#include "hphp/runtime/base/stats.h"
#include "hphp/runtime/base/strings.h"

#include "hphp/runtime/vm/jit/irgen-interpone.h"
#include "hphp/runtime/vm/jit/irgen-exit.h"
#include "hphp/runtime/vm/jit/irgen-internal.h"

namespace HPHP { namespace jit { namespace irgen {

namespace {

//////////////////////////////////////////////////////////////////////

void implAGet(IRGS& env, SSATmp* classSrc) {
  if (classSrc->type() <= TStr) {
    push(env, ldCls(env, classSrc));
    return;
  }
  push(env, gen(env, LdObjClass, classSrc));
}

const StaticString s_FATAL_NULL_THIS(Strings::FATAL_NULL_THIS);
bool checkThis(IRGS& env, SSATmp* ctx) {
  auto fail = [&] {
    auto const err = cns(env, s_FATAL_NULL_THIS.get());
    gen(env, RaiseError, err);
  };
  if (!ctx->type().maybe(TObj)) {
    fail();
    return false;
  }
  ifThen(
    env,
    [&] (Block* taken) {
      gen(env, CheckCtxThis, taken, ctx);
    },
    [&] {
      hint(env, Block::Hint::Unlikely);
      fail();
    }
  );
  return true;
}

//////////////////////////////////////////////////////////////////////

}

void emitAGetC(IRGS& env) {
  auto const name = topC(env);
  if (name->type().subtypeOfAny(TObj, TStr)) {
    popC(env);
    implAGet(env, name);
    decRef(env, name);
  } else {
    interpOne(env, TCls, 1);
  }
}

void emitAGetL(IRGS& env, int32_t id) {
  auto const ldrefExit = makeExit(env);
  auto const ldPMExit = makePseudoMainExit(env);
  auto const src = ldLocInner(env, id, ldrefExit, ldPMExit, DataTypeSpecific);
  if (src->type().subtypeOfAny(TObj, TStr)) {
    implAGet(env, src);
  } else {
    PUNT(AGetL);
  }
}

void emitCGetL(IRGS& env, int32_t id) {
  auto const ldrefExit = makeExit(env);
  auto const ldPMExit = makePseudoMainExit(env);
  auto const loc = ldLocInnerWarn(
    env,
    id,
    ldrefExit,
    ldPMExit,
    DataTypeCountnessInit
  );
  pushIncRef(env, loc);
}

void emitCGetQuietL(IRGS& env, int32_t id) {
  auto const ldrefExit = makeExit(env);
  auto const ldPMExit = makePseudoMainExit(env);
  auto const loc = ldLocInner(
    env,
    id,
    ldrefExit,
    ldPMExit,
    DataTypeCountnessInit
  );
  pushIncRef(env, loc);
}

void emitCUGetL(IRGS& env, int32_t id) {
  auto const ldrefExit = makeExit(env);
  auto const ldPMExit = makePseudoMainExit(env);
  pushIncRef(env, ldLocInner(env, id, ldrefExit, ldPMExit, DataTypeGeneric));
}

void emitPushL(IRGS& env, int32_t id) {
  assertTypeLocal(env, id, TInitCell);  // bytecode invariant
  auto* locVal = ldLoc(env, id, makeExit(env), DataTypeGeneric);
  push(env, locVal);
  stLocRaw(env, id, fp(env), cns(env, TUninit));
}

void emitCGetL2(IRGS& env, int32_t id) {
  auto const ldrefExit = makeExit(env);
  auto const ldPMExit = makePseudoMainExit(env);
  auto const oldTop = pop(env, DataTypeGeneric);
  auto const val = ldLocInnerWarn(
    env,
    id,
    ldrefExit,
    ldPMExit,
    DataTypeCountnessInit
  );
  pushIncRef(env, val);
  push(env, oldTop);
}

template<class F>
SSATmp* boxHelper(IRGS& env, SSATmp* value, F rewrite) {
  auto const t = value->type();
  if (t <= TCell) {
    if (t <= TUninit) {
      value = cns(env, TInitNull);
    }
    value = gen(env, Box, value);
    rewrite(value);
  } else if (t.maybe(TCell)) {
    value = cond(env,
                 [&](Block* taken) {
                   auto const ret = gen(env, CheckType, TBoxedInitCell,
                                        taken, value);
                   env.irb->constrainValue(ret, DataTypeSpecific);
                   return ret;
                 },
                 [&](SSATmp* box) { // Next: value is Boxed
                   return box;
                 },
                 [&] { // Taken: value is not Boxed
                   auto const tmpType = t - TBoxedInitCell;
                   assertx(tmpType <= TCell);
                   auto const tmp = gen(env, AssertType, tmpType, value);
                   auto const ret = gen(env, Box, tmp);
                   rewrite(ret);
                   return ret;
                 });
  }
  return value;
}

void emitVGetL(IRGS& env, int32_t id) {
  auto const value = ldLoc(env, id, makeExit(env), DataTypeCountnessInit);
  auto const boxed = boxHelper(
    env,
    gen(env, AssertType, TCell | TBoxedInitCell, value),
    [&] (SSATmp* v) {
      stLocRaw(env, id, fp(env), v);
    });

  pushIncRef(env, boxed);
}

void emitBox(IRGS& env) {
  push(env, gen(env, Box, pop(env, DataTypeGeneric)));
}

void emitBoxR(IRGS& env) {
  auto const value = pop(env, DataTypeGeneric);
  auto const boxed = boxHelper(
    env,
    gen(env, AssertType, TCell | TBoxedInitCell, value),
    [] (SSATmp* ) {});
  push(env, boxed);
}

void emitUnsetL(IRGS& env, int32_t id) {
  auto const prev = ldLoc(env, id, makeExit(env), DataTypeCountness);
  stLocRaw(env, id, fp(env), cns(env, TUninit));
  decRef(env, prev);
}

void emitBindL(IRGS& env, int32_t id) {
  if (curFunc(env)->isPseudoMain()) {
    interpOne(env, TBoxedInitCell, 1);
    return;
  }

  auto const ldPMExit = makePseudoMainExit(env);
  auto const newValue = popV(env);
  // Note that the IncRef must happen first, for correctness in a
  // pseudo-main: the destructor could decref the value again after
  // we've stored it into the local.
  pushIncRef(env, newValue);
  auto const oldValue = ldLoc(env, id, ldPMExit, DataTypeSpecific);
  stLocRaw(env, id, fp(env), newValue);
  decRef(env, oldValue);
}

void emitSetL(IRGS& env, int32_t id) {
  auto const ldrefExit = makeExit(env);
  auto const ldPMExit = makePseudoMainExit(env);

  // since we're just storing the value in a local, this function doesn't care
  // about the type of the value. stLoc needs to IncRef the value so it may
  // constrain it further.
  auto const src = popC(env, DataTypeGeneric);
  pushStLoc(env, id, ldrefExit, ldPMExit, src);
}

void emitInitThisLoc(IRGS& env, int32_t id) {
  if (!curFunc(env)->mayHaveThis()) {
    // Do nothing if this is null
    return;
  }
  auto const ldrefExit = makeExit(env);
  auto const ctx       = ldCtx(env);
  ifElse(env,
         [&] (Block* skip) { gen(env, CheckCtxThis, skip, ctx); },
         [&] {
           auto const oldLoc = ldLoc(env, id, ldrefExit, DataTypeCountness);
           auto const this_  = gen(env, CastCtxThis, ctx);
           gen(env, IncRef, this_);
           stLocRaw(env, id, fp(env), this_);
           decRef(env, oldLoc);
         });
}

void emitPrint(IRGS& env) {
  auto const type = topC(env)->type();
  if (!type.subtypeOfAny(TInt, TBool, TNull, TStr)) {
    interpOne(env, TInt, 1);
    return;
  }

  auto const cell = popC(env);

  Opcode op;
  if (type <= TStr) {
    op = PrintStr;
  } else if (type <= TInt) {
    op = PrintInt;
  } else if (type <= TBool) {
    op = PrintBool;
  } else {
    assertx(type <= TNull);
    op = Nop;
  }
  // the print helpers decref their arg, so don't decref pop'ed value
  if (op != Nop) {
    gen(env, op, cell);
  }
  push(env, cns(env, 1));
}

void emitUnbox(IRGS& env) {
  auto const exit = makeExit(env);
  auto const srcBox = popV(env);
  auto const unboxed = unbox(env, srcBox, exit);
  pushIncRef(env, unboxed);
  decRef(env, srcBox);
}

void emitThis(IRGS& env) {
  auto const ctx = ldCtx(env);
  if (!checkThis(env, ctx)) {
    // Unreachable
    push(env, cns(env, TInitNull));
    return;
  }
  auto const this_ = gen(env, CastCtxThis, ctx);
  pushIncRef(env, this_);
}

void emitCheckThis(IRGS& env) {
  auto const ctx = ldCtx(env);
  checkThis(env, ctx);
}

void emitBareThis(IRGS& env, BareThisOp subop) {
  auto const ctx = ldCtx(env);
  if (!ctx->type().maybe(TObj)) {
    if (subop == BareThisOp::NoNotice) {
      push(env, cns(env, TInitNull));
      return;
    }
    assertx(subop != BareThisOp::NeverNull);
    interpOne(env, TInitNull, 0); // will raise notice and push null
    return;
  }

  if (subop == BareThisOp::NoNotice) {
    auto thiz = cond(env,
                     [&](Block* taken) {
                       gen(env, CheckCtxThis, taken, ctx);
                     },
                     [&] {
                       auto t = gen(env, CastCtxThis, ctx);
                       gen(env, IncRef, t);
                       return t;
                     },
                     [&] {
                       return cns(env, TInitNull);
                     });
    push(env, thiz);
    return;
  }

  if (subop == BareThisOp::NeverNull) {
    env.irb->fs().setThisAvailable();
  } else {
    gen(env, CheckCtxThis, makeExitSlow(env), ctx);
  }

  pushIncRef(env, gen(env, CastCtxThis, ctx));
}

void emitClone(IRGS& env) {
  if (!topC(env)->isA(TObj)) PUNT(Clone-NonObj);
  auto const obj        = popC(env);
  push(env, gen(env, Clone, obj));
  decRef(env, obj);
}

void emitLateBoundCls(IRGS& env) {
  auto const clss = curClass(env);
  if (!clss) {
    // no static context class, so this will raise an error
    interpOne(env, TCls, 0);
    return;
  }
  auto const ctx = ldCtx(env);
  push(env, gen(env, LdClsCtx, ctx));
}

void emitSelf(IRGS& env) {
  auto const clss = curClass(env);
  if (clss == nullptr) {
    interpOne(env, TCls, 0);
  } else {
    push(env, cns(env, clss));
  }
}

void emitParent(IRGS& env) {
  auto const clss = curClass(env);
  if (clss == nullptr || clss->parent() == nullptr) {
    interpOne(env, TCls, 0);
  } else {
    push(env, cns(env, clss->parent()));
  }
}

void emitNameA(IRGS& env) {
  push(env, gen(env, LdClsName, popA(env)));
}

//////////////////////////////////////////////////////////////////////

void emitCastArray(IRGS& env) {
  auto const src = popC(env);
  push(env, gen(env, ConvCellToArr, src));
}

void emitCastVec(IRGS& env) {
  auto const src = popC(env);

  auto const raise = [&](const char* type) {
    gen(
      env,
      RaiseWarning,
      cns(
        env,
        makeStaticString(folly::sformat("{} to vec conversion", type))
      )
    );
    decRef(env, src);
    return cns(env, staticEmptyVecArray());
  };

  push(
    env,
    [&] {
      if (src->isA(TVec))    return src;
      if (src->isA(TArr))    return gen(env, ConvArrToVec, src);
      if (src->isA(TDict))   return gen(env, ConvDictToVec, src);
      if (src->isA(TKeyset)) return gen(env, ConvKeysetToVec, src);
      if (src->isA(TObj))    return gen(env, ConvObjToVec, src);
      if (src->isA(TNull))   return raise("Null");
      if (src->isA(TBool))   return raise("Bool");
      if (src->isA(TInt))    return raise("Int");
      if (src->isA(TDbl))    return raise("Double");
      if (src->isA(TStr))    return raise("String");
      if (src->isA(TRes))    return raise("Resource");
      not_reached();
    }()
  );
}

void emitCastDict(IRGS& env) {
  auto const src = popC(env);

  auto const raise = [&](const char* type) {
    gen(
      env,
      RaiseWarning,
      cns(
        env,
        makeStaticString(folly::sformat("{} to dict conversion", type))
      )
    );
    decRef(env, src);
    return cns(env, staticEmptyDictArray());
  };

  push(
    env,
    [&] {
      if (src->isA(TDict))    return src;
      if (src->isA(TArr))     return gen(env, ConvArrToDict, src);
      if (src->isA(TVec))     return gen(env, ConvVecToDict, src);
      if (src->isA(TKeyset))  return gen(env, ConvKeysetToDict, src);
      if (src->isA(TObj))     return gen(env, ConvObjToDict, src);
      if (src->isA(TNull))    return raise("Null");
      if (src->isA(TBool))    return raise("Bool");
      if (src->isA(TInt))     return raise("Int");
      if (src->isA(TDbl))     return raise("Double");
      if (src->isA(TStr))     return raise("String");
      if (src->isA(TRes))     return raise("Resource");
      not_reached();
    }()
  );
}

void emitCastKeyset(IRGS& env) {
  auto const src = popC(env);

  auto const raise = [&](const char* type) {
    gen(
      env,
      RaiseWarning,
      cns(
        env,
        makeStaticString(folly::sformat("{} to keyset conversion", type))
      )
    );
    decRef(env, src);
    return cns(env, staticEmptyKeysetArray());
  };

  push(
    env,
    [&] {
      if (src->isA(TKeyset))  return src;
      if (src->isA(TArr))     return gen(env, ConvArrToKeyset, src);
      if (src->isA(TVec))     return gen(env, ConvVecToKeyset, src);
      if (src->isA(TDict))    return gen(env, ConvDictToKeyset, src);
      if (src->isA(TObj))     return gen(env, ConvObjToKeyset, src);
      if (src->isA(TNull))    return raise("Null");
      if (src->isA(TBool))    return raise("Bool");
      if (src->isA(TInt))     return raise("Int");
      if (src->isA(TDbl))     return raise("Double");
      if (src->isA(TStr))     return raise("String");
      if (src->isA(TRes))     return raise("Resource");
      not_reached();
    }()
  );
}

void emitCastBool(IRGS& env) {
  auto const src = popC(env);
  push(env, gen(env, ConvCellToBool, src));
  decRef(env, src);
}

void emitCastDouble(IRGS& env) {
  auto const src = popC(env);
  push(env, gen(env, ConvCellToDbl, src));
  decRef(env, src);
}

void emitCastInt(IRGS& env) {
  auto const src = popC(env);
  push(env, gen(env, ConvCellToInt, src));
  decRef(env, src);
}

void emitCastObject(IRGS& env) {
  auto const src = popC(env);
  push(env, gen(env, ConvCellToObj, src));
}

void emitCastString(IRGS& env) {
  auto const src = popC(env);
  push(env, gen(env, ConvCellToStr, src));
  decRef(env, src);
}

void emitIncStat(IRGS& env, int32_t counter, int32_t value) {
  if (!Stats::enabled()) return;
  gen(env, IncStat, cns(env, counter), cns(env, value), cns(env, false));
}

//////////////////////////////////////////////////////////////////////

void emitPopA(IRGS& env) { popA(env); }
void emitPopC(IRGS& env) { popDecRef(env, DataTypeGeneric); }
void emitPopV(IRGS& env) { popDecRef(env, DataTypeGeneric); }
void emitPopR(IRGS& env) { popDecRef(env, DataTypeGeneric); }

void emitDir(IRGS& env)  { push(env, cns(env, curUnit(env)->dirpath())); }
void emitFile(IRGS& env) { push(env, cns(env, curUnit(env)->filepath())); }

void emitDup(IRGS& env) { pushIncRef(env, topC(env)); }

//////////////////////////////////////////////////////////////////////

void emitArray(IRGS& env, const ArrayData* x) {
  assertx(x->isPHPArray());
  push(env, cns(env, x));
}

void emitVec(IRGS& env, const ArrayData* x) {
  assertx(x->isVecArray());
  push(env, cns(env, x));
}

void emitDict(IRGS& env, const ArrayData* x) {
  assertx(x->isDict());
  push(env, cns(env, x));
}

void emitKeyset(IRGS& env, const ArrayData* x) {
  assertx(x->isKeyset());
  push(env, cns(env, x));
}

void emitString(IRGS& env, const StringData* s) { push(env, cns(env, s)); }
void emitInt(IRGS& env, int64_t val)            { push(env, cns(env, val)); }
void emitDouble(IRGS& env, double val)          { push(env, cns(env, val)); }
void emitTrue(IRGS& env)                        { push(env, cns(env, true)); }
void emitFalse(IRGS& env)                       { push(env, cns(env, false)); }

void emitNull(IRGS& env)       { push(env, cns(env, TInitNull)); }
void emitNullUninit(IRGS& env) { push(env, cns(env, TUninit)); }

//////////////////////////////////////////////////////////////////////

void emitNop(IRGS&)                {}
void emitEntryNop(IRGS&)           {}
void emitBoxRNop(IRGS& env) {
  assertTypeStack(env, BCSPRelOffset{0}, TBoxedCell);
}
void emitUnboxRNop(IRGS& env) {
  assertTypeStack(env, BCSPRelOffset{0}, TCell);
}
void emitRGetCNop(IRGS&)           {}
void emitFPassC(IRGS&, int32_t)    {}
void emitFPassVNop(IRGS&, int32_t) {}
void emitDefClsNop(IRGS&, Id)      {}
void emitBreakTraceHint(IRGS&)     {}

//////////////////////////////////////////////////////////////////////

}}}
