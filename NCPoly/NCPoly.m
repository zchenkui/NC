(*  NCPoly.m                                                               *)
(*  Author: Mauricio de Oliveira                                           *)
(*    Date: July 2009                                                      *)
(* Version: 0.1 ( initial implementation )                                 *)

BeginPackage[ "NCPoly`" ];

(* 
   These functions are not implemented here. 
   They are meant to be overload by your favorite implementation 
*)

Clear[NCPoly,
      NCPolyOrderType,
      NCPolyLexDeg,NCPolyDegLex,NCPolyDegLexGraded,
      NCPolyDisplayOrder,
      NCPolyConstant,
      NCPolyMonomial,
      NCPolyMonomialQ,
      NCPolyDegree,
      NCPolyLeadingTerm,
      NCPolyLeadingMonomial,
      NCPolyGetCoefficients,
      NCPolyCoefficient,
      NCPolyGetDigits,
      NCPolyGetIntegers,
      NCPolyNumberOfVariables,
      NCPolySum,
      NCPolyProduct,
      NCPolyReduce,
      NCPolyToRule,
      NCPolyFullReduce,
      NCPolyQuotientExpand,
      NCPolyNormalize];

(* The following generic functions are implemented here *)

Clear[NCFromDigits,
      NCIntegerDigits,
      NCPadAndMatch,
      NCPolyDivideDigits,
      NCPolyDivideLeading,
      NCPolyDisplay];

Get["NCPoly.usage"];

Begin["`Private`"];

  (* Some facilities are implemented here. 
     ATTENTION: the main driver function are not implemented. *)

  (* Constant Constructor *)

  NCPolyConstant[value_, n_] := 
    NCPolyMonomial[Rule[{0,0}, value], n];

  (* Operators *)

  NCPolyDegree[x_] := 0;

  NCPoly /: Times[0, s_NCPoly] := 0;

  NCPoly /: Plus[r_, s_NCPoly] := 
    NCPolySum[NCPolyConstant[r, s[[1]]], s];

  NCPoly /: Plus[r_NCPoly, s_NCPoly] := NCPolySum[r, s];

  (* NonCommutativeMultiply *)
  NCPolyProduct[r_, s_NCPoly] := Times[r, s];
  NCPolyProduct[r_NCPoly, s_] := Times[s, r];

  NCPolyProduct[r_, s_, t__] := 
    NCPolyProduct[NCPolyProduct[r,s], t];

  (* NonCommutativeMultiply *)
  NCPoly /: NonCommutativeMultiply[r_NCPoly, s_NCPoly] := NCPolyProduct[r, s];

  Clear[QuotientExpand];
  QuotientExpand[ {c_, l_NCPoly, r_NCPoly}, g_NCPoly ] := c * NCPolyProduct[l, g, r];
  QuotientExpand[ {c_, l_,       r_NCPoly}, g_NCPoly ] := c * l * NCPolyProduct[g, r];
  QuotientExpand[ {c_, l_NCPoly, r_}, g_NCPoly ] := c * r * NCPolyProduct[l, g];
  QuotientExpand[ {c_, l_,       r_}, g_NCPoly ] := c * l * r * g;

  QuotientExpand[ {l_NCPoly, r_NCPoly}, g_NCPoly ] := NCPolyProduct[l, g, r];
  QuotientExpand[ {l_,       r_NCPoly}, g_NCPoly ] := l * NCPolyProduct[g, r];
  QuotientExpand[ {l_NCPoly, r_}, g_NCPoly ] := r * NCPolyProduct[l, g];
  QuotientExpand[ {l_,       r_}, g_NCPoly ] := r * l * g;

  NCPolyQuotientExpand[q_List, g_NCPoly] := 
    Plus @@ Map[ QuotientExpand[#, g]&, q ];

  NCPolyQuotientExpand[q_List, {g__NCPoly}] :=
   Plus @@ Map[ NCPolyQuotientExpand[Part[#,1],{g}[[Part[#,2]]]]&, q];

  NCPolyDivideDigits[{f__Integer}, {g__Integer}] := 
    Flatten[ ReplaceList[{f}, Join[{a___,g,b___}] :> {{a}, {b}}, 1], 1];

  NCPolyDivideLeading[lf_Rule, lg_Rule, base_] := 
    Flatten[
      ReplaceList[
        NCIntegerDigits[lf[[1]], base] 
       ,Join[{a___}, NCIntegerDigits[lg[[1]], base], {b___}] 
          :> { lf[[2]]/lg[[2]], 
               NCPolyMonomial[{a}, base], 
               NCPolyMonomial[{b}, base] }
       ,1
      ],
      1
    ];

  NCPolyFullReduce[{g__NCPoly}, complete_:False, debugLevel_:0] := Block[
    { r = {g}, m, qi, ri, rii, i, modified = False },

    m = Length[r];
    If[ m > 1,
      For [i = 1, i <= m, i++, 
        rii = r[[i]];
        {qi, ri} = NCPolyReduce[rii, Drop[r, {i}], complete, debugLevel];
        If [ ri =!= 0,
             If [ ri =!= rii,
               Part[r, i] = ri;
               modified = True;
             ];
            ,
             r = Delete[r, i];
             i--; m--;
             If[ m <= 1, Break[]; ];
        ];
      ];
    ];

    Return[ If [ modified, NCPolyFullReduce[r, complete, debugLevel], r] ];

  ];

  NCPolyReduce[{f__NCPoly}, {g__NCPoly}, complete_:False, debugLevel_:0] := 
  Block[{ gs = {g}, fs = {f}, m, qi, ri, i },

    m = Length[fs];
    For [i = 1, i <= m, i++, 
      {qi, ri} = NCPolyReduce[fs[[i]], gs, complete, debugLevel];
      If [ ri =!= 0,
           (* If not zero reminder, update *)
           Part[fs, i] = ri;
          ,
           (* If zero reminder, remove *)
           fs = Delete[fs, i];
           i--; m--;
      ];
    ];

    Return[fs];

  ];

  NCPolyReduce[{g__NCPoly}, complete_:False, debugLevel_:0] := Block[
    { r = {g}, m, qi, ri, i },

    m = Length[r];
    If[ m > 1,
      For [i = 1, i <= m, i++, 
        {qi, ri} = NCPolyReduce[r[[i]], Drop[r, {i}], complete, debugLevel];
        If [ ri =!= 0,
             (* If not zero reminder, update *)
             Part[r, i] = ri;
            ,
             (* If zero reminder, remove *)
             r = Delete[r, i];
             i--; m--;
             If[ m <= 1, Break[]; ];
        ];
      ];
    ];

    Return[r];

  ];

  NCPolyReduce[f_NCPoly, {g__NCPoly}, complete_:False, debugLevel_:0] := Block[
    { gs = {g}, m, ff, q, qi, r, i },

    m = Length[gs];
    ff = f;
    q = {};
    i = 1;
    While [i <= m, 
      (* Reduce current dividend *)
      {qi, r} = NCPolyReduce[ff, gs[[i]], complete, debugLevel];
      If [ r =!= ff,
        (* Append to remainder *)
        AppendTo[q, {qi, i} ];
        (* If zero reminder *)
        If[ r === 0,
           (* terminate *)
           If[ debugLevel > 1, Print["no reminder, terminate"]; ];
           Break[];
          ,
           (* update dividend, go back to first term and continue *)
           ff = r;
           i = 1;
           Continue[];
        ];
      ];
      (* continue *)
      i++;
    ];

    Return[{q,r}];

  ];

  (* Auxiliary routines related to degree and integer indexing *)

  SelectDigits[p_List, {min_Integer, max_Integer}] :=
    Replace[ Map[ If[min < # <= max, #, 0]&, p ]
            ,
             {Longest[0...],x___} -> {x}
    ];

  (* From digits *)

  NCFromDigits[{}, {base__}] := 
    Table[0, {i, Length[{base}] + 1}];

  NCFromDigits[{}, base_] := 
    Table[0, {i, 2}];

  NCFromDigits[{p__List}, base_] := 
    Map[NCFromDigits[#, base]&, {p}];

  NCFromDigits[p_List, {base__Integer}] := 
    Append[ Reverse[ BinCounts[p, {Prepend[Accumulate[{base}], 0]}] ], FromDigits[p, Plus @@ {base}] ];

  (* DEG Ordered *)
  NCFromDigits[p_List, base_Integer:10] := 
    {Length[p], FromDigits[p, base]};

  (* IntegerDigits *)

  (* DEG Ordered *)
  NCIntegerDigits[{d_Integer, n_Integer}, base_Integer:10] := 
    IntegerDigits[n, base, d];

  NCIntegerDigits[{d_Integer, n_Integer}, base_Integer:10, len_Integer] := 
    IntegerDigits[n, base, len];

  NCIntegerDigits[{d__Integer, n_Integer}, {base__Integer}] := 
    IntegerDigits[n, Plus @@ {base}, Plus @@ {d}];

  NCIntegerDigits[{d__Integer, n_Integer}, {base__Integer}, len_Integer] := 
    IntegerDigits[n, Plus @@ {base}, len];

  NCIntegerDigits[dn_List, base_Integer] :=
    Map[NCIntegerDigits[#, base]&, dn] /; Depth[dn] === 3;

  NCIntegerDigits[dn_List, base_Integer, len_Integer] :=
    Map[NCIntegerDigits[#, base, len]&, dn] /; Depth[dn] === 3;

  NCIntegerDigits[dn_List, {base__Integer}] :=
    Map[NCIntegerDigits[#, {base}]&, dn] /; Depth[dn] === 3;

  NCIntegerDigits[dn_List, {base__Integer}, len_Integer] :=
    Map[NCIntegerDigits[#, {base}, len]&, dn] /; Depth[dn] === 3;

  (* Auxiliary routines for pattern matching of monomials *)

  Clear[ShiftPattern];
  ShiftPattern[g_List, i_Integer] :=
   { Join[Drop[g, i], {r___ : 1}] -> {{Take[g, i], {}}, {{}, {r}}}, 
     Join[{l___ : 1}, Drop[g, -i]] -> {{{}, Take[g, -i]}, {{l}, {}}} };

  NCPadAndMatch[g1_List, g2_List] := Block[
    { i = 1, result = {} },

    (* i = 0 *)

    (*
      Print["NCPadAndMatch"];
      Print["g1 = ", g1];
      Print["g2 = ", g2];
    *)

    result = ReplaceList[g1, Join[{l___}, g2, {r___}] -> {{l}, {r}}];

    (*
      Print["result 1 = ", result]; 
    *)

    If[ result =!= {}
       ,

        If[ Flatten[result] =!= {},

            (* BUG FIXED:
               result = {Join[{{{},{}}}, result]}; 
            *)

            result = Map[Join[{{{},{}}}, {#}]&, result];

            (*
              Print["result 2 = ", result]; 
            *)

            Return[result];
        ];

        (* g1 === g2, continue with NCPadAndMatch *)
        result = {};
        While[ And[result === {}, i < Length[g2]]
              ,
               result = ReplaceList[g1, Part[ShiftPattern[g2, i], 1]];
               i++;
        ];

        (*
          Print["result 3 = ", result];
        *)

        Return[result];
    ];

    (* g1 =!= g2, continue with MCM *)
    (* i >= 1 *)

    (* BUG FIXED: 
         While[ And[result === {}, i < Length[g2]], 
       would generate only first obstruction.
    *)

    result = Join[ result, 
                   Join @@ 
                     Table[ Flatten[Map[ReplaceList[g1, #] &, 
                                        ShiftPattern[g2, i]], 1], 
                            {i,1,Length[g2]-1} ] ];

    (*
      Print["result 4 = ", result];
    *)

    Return[result];

  ] /; Length[g2] <= Length[g1];

  (* Takes care of the case when Length[g2] > Length[g1] *)
  NCPadAndMatch[g1_List, g2_List] := 
    Map[Reverse, NCPadAndMatch[g2, g1], 1];

  (* Sorting *)

  Unprotect[Sort];
  Sort[{l__NCPoly}] := Part[{l}, Ordering[Map[NCPolyLeadingTerm, {l}]]];
  Protect[Sort];

  NCPoly /: Greater[l__NCPoly] := 
    Greater @@ Ordering[List @@ Map[NCPolyLeadingTerm, {l}]];

  NCPoly /: Less[l__NCPoly] := 
    Less @@ Ordering[List @@ Map[NCPolyLeadingTerm, {l}]];

  (* PolyToRule *)
  NCPolyToRule[p_NCPoly] := Block[
    {pN, leadF},

    pN = NCPolyNormalize[p];
    leadF = NCPolyLeadingMonomial[pN];

    Return[leadF -> (leadF - pN)];
  ];

  NCPolyToRule[{p___NCPoly}] := 
    Map[NCPolyToRule, {p}];

  (* Display *)

  NCPolyVariables[p_NCPoly] := 
    Table[Symbol[FromCharacterCode[ToCharacterCode["@"]+i]], 
          {i, NCPolyNumberOfVariables[p]}];    
  
  NCPolyDisplay[{p__NCPoly}] := Map[NCPolyDisplay, {p}];

  NCPolyDisplay[p_NCPoly] := NCPolyDisplay[p, NCPolyVariables[p]];

  NCPolyDisplay[p_NCPoly, vars_List, 
                plus_:List, style_:(Style[#,Bold]&)] := 
    plus @@ 
      MapThread[
        Times, 
        { NCPolyGetCoefficients[p],
          Apply[style[Dot[##]]&, Map[Part[Flatten[vars],#]&, 
                                     NCPolyGetDigits[p] + 1] /. {} -> 1, 1] }
      ];

  NCPolyDisplay[p_, vars_List:{}, ___] := p;

  NCPolyDisplay[p___] := $Failed;
      
End[]
EndPackage[]
