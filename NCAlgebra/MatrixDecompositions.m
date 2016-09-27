(* :Title: 	MatrixDecompositions.m *)

(* :Authors: 	Mauricio C. de Oliveira and Burack Guven *)

(* :Context: 	MatrixDecompositions` *)

(* :Summary: *)

(* :Alias:   *)

(* :Warnings: *)

(* :History: *)

BeginPackage[ "MatrixDecompositions`" ];

Clear[LUDecompositionWithPartialPivoting,
      LUDecompositionWithCompletePivoting,
      LDLDecomposition,
      UpperTriangularSolve,
      LowerTriangularSolve,
      LUInverse,
      GetLUMatrices, GetLDUMatrices,
      LUPartialPivoting, LUCompletePivoting];

Get["MatrixDecompositions.usage"];
            
MatrixDecompositions::WrongDimensions = \
"Righ and left-hand side dimensions DO NOT MATCH.";
MatrixDecompositions::Square = "The input matrix is not square.";
MatrixDecompositions::SelfAdjoint = "The input matrix is not self-adjoint.";
MatrixDecompositions::Singular = "The input matrix appears to be singular.";
MatrixDecompositions::Incomplete = \
"The factorization failed. Return factors are incomplete";

LUDecompositionWithCompletePivoting::SuppressPivoting = \
"LUDecompositionWithCompletePivoting does not support SuppressPivoting. \
Use LUDecompositionWithPartialPivoting instead.";

Options[MatrixDecompositions] = {
  ZeroTest -> PossibleZeroQ,
  LeftDivide -> (Divide[#2,#1]&),
  RightDivide -> Divide,
  Dot -> Dot,
  SuppressPivoting -> False,
  SelfAdjointMatrixQ -> HermitianMatrixQ
};

Options[LUDecompositionWithPartialPivoting] = {
  Pivoting -> LUPartialPivoting
};

Options[LUDecompositionWithCompletePivoting] = {
  Pivoting -> LUCompletePivoting
};

Options[LDLDecomposition] = {
  PartialPivoting -> LUPartialPivoting,
  CompletePivoting -> LUCompletePivoting,
  Inverse -> Inverse
};

Begin[ "`Private`" ]

  (* Get LU Matrices *)

  GetLUMatrices[ldu_, p_, q_, rank_] := Module[
    {l,u},

    (* Extract L and U factor *)
    {l,u} = GetLUMatrices[ldu];

    (* Perform permutations and truncate to rank *)
    l = l[[All, 1;;rank]];
    l[[p,All]] = l;
    u = u[[1;;rank, All]];
    u[[All,q]] = u;

    Return[{l,u}];
  ];

  GetLUMatrices[ldu_] := Module[
    {n,m,mats},
    {m,n} = Dimensions[ldu];

    mats = If[n >= m, 
      {
	ldu[[1;;m,1;;m]] SparseArray[{i_,j_} /; j < i -> 1, {m,m}] 
	   + SparseArray[{i_,i_} -> 1, {m,m}],
	ldu SparseArray[{i_,j_} /; j >= i -> 1, {m,n}]
      },
      {
	ldu SparseArray[{i_,j_} /; j < i -> 1, {m,n}]
	   + SparseArray[{i_,i_} -> 1, {m,n}],
	ldu[[1;;n,1;;n]] SparseArray[{i_,j_} /; j >= i -> 1, {n,n}]
      }
    ];

    Return[mats];

  ];

  
  (* GetLDUMatrices *)
  
  GetLDUMatrices[ldl_, s_] := Module[
    {n,m,mats,id,lm,dm,S},
    {m,n} = Dimensions[ldl];

    S = Accumulate[s];
    S = Delete[S, Position[s, 1]];
    id = SparseArray[{i_, i_} -> 1, {m, m}];
    dm = SparseArray[
           Thread[Transpose[{Join[S, S - 1], Join[S - 1, S]}] -> 1]
           , 
           {m, m}
         ] + id;
    lm = SparseArray[{i_, j_} /; j <= i -> 1, {m, m}] 
         (SparseArray[{i_, j_} /; j <= i -> 1, {m, m}] - dm);

    Return[{ldl lm + id, ldl dm, ldl Transpose[lm] + id}];

  ];

  (* Upper triangular solve (Back substitution) *)
  UpperTriangularSolve[u_, b_?VectorQ, opts:OptionsPattern[{}]] :=
    Flatten[UpperTriangularSolve[u, Transpose[{b}], opts]];

  UpperTriangularSolve[u_, b_?MatrixQ, opts:OptionsPattern[{}]] := Module[
     {options, zeroTest, pivoting, dot, leftDivide,
      U,X,m,n,j},

     (* process options *)

     options = Flatten[{opts}];

     zeroTest = ZeroTest
	    /. options
	    /. Options[MatrixDecompositions, ZeroTest];

     leftDivide = LeftDivide
	    /. options
	    /. Options[MatrixDecompositions, LeftDivide];

     dot = Dot
	    /. options
	    /. Options[MatrixDecompositions, Dot];

     (* Solve *)
      
     U = u;
     {m,n} = Dimensions[U];
     If[m != n, Message[MatrixDecompositions::Square]; Return[]];
      
     (* Initialize solution *)
     X = b;
     {n,$trash} = Dimensions[X];
     If[m != n, Message[MatrixDecompositions::WrongDimensions]; Return[]];

     (*
     Print["m = ", m];
     Print["n = ", n];
     *)

     For [j = m, j >= 2, j--,

       (* Print["j = ", j]; *)

       (* If zero diagonal, singular *)
       If[ zeroTest[U[[j,j]]],
	 Message[MatrixDecompositions::Singular];
       ];

       (* Print["X- = ", Normal[X]]; *)

       (* Update matrix *)
       X[[j]] = leftDivide[ U[[j,j]], X[[j]] ];
          
       X[[1;;j-1]] -= dot[ U[[1;;j-1,{j}]], {X[[j]]} ];

       (* Print["X+ = ", Normal[X]]; *)

    ];

    (* If zero diagonal, singular *)
    If[ zeroTest[U[[1,1]]],
      Message[MatrixDecompositions::Singular];
    ];

    X[[1]] = leftDivide[ U[[1,1]], X[[1]] ];

    Return[X];
  ];

  (* Lower triangular solve (Back substitution) *)
  LowerTriangularSolve[l_, b_?VectorQ, opts:OptionsPattern[{}]] :=
    Flatten[LowerTriangularSolve[l, Transpose[{b}], opts]];

  LowerTriangularSolve[l_, b_?MatrixQ, opts:OptionsPattern[{}]] := Module[
     {options, zeroTest, pivoting, dot, leftDivide,
      L,X,m,n,j},

     (* process options *)

     options = Flatten[{opts}];

     zeroTest = ZeroTest
	    /. options
	    /. Options[MatrixDecompositions, ZeroTest];

     leftDivide = LeftDivide
	    /. options
	    /. Options[MatrixDecompositions, LeftDivide];

     dot = Dot
	    /. options
	    /. Options[MatrixDecompositions, Dot];

     (* Solve *)

     L = l;
     {m,n} = Dimensions[L];
     If[m != n, Message[MatrixDecompositions::Square]; Return[]];

     (* Initialize solution *)
     X = b;
     {n,$trash} = Dimensions[X];
     If[m != n, Message[MatrixDecompositions::WrongDimensions]; Return[]];

     (*
     Print["m = ", m];
     Print["n = ", n];
     *)

     For [j = 1, j <= m - 1, j++,

       (* Print["j = ", j]; *)

       (* If zero diagonal, singular *)
       If[ zeroTest[L[[j,j]]],
	 Message[MatrixDecompositions::Singular];
       ];

       (* Print["X- = ", Normal[X]]; *)

       (* Update matrix *)
       X[[j]] = leftDivide[ L[[j,j]], X[[j]] ];
          
       X[[j+1;;m]] -= dot[ L[[j+1;;m,{j}]], {X[[j]]} ];

       (* Print["X+ = ", Normal[X]]; *)

    ];

    (* If zero diagonal, singular *)
    If[ zeroTest[L[[m,m]]],
      Message[MatrixDecompositions::Singular];
    ];

    X[[m]] = leftDivide[ L[[m,m]], X[[m]] ];

    Return[X];
  ];

  (* LU Inverse *)
  (* 
     L U inv[A] = P A inv[A] = P
     inv[A] = U \ (L \ P)
  *)
  
  LUInverse[A_?MatrixQ, opts:OptionsPattern[{}]] := Module[
     {lu,p,l,u,id,m,n},

     (* Solve *)
     {m,n} = Dimensions[A];
     id = IdentityMatrix[m];
     If[m != n
        , 
        Message[MatrixDecompositions::Square]; 
        Return[id];
     ];
      
     {lu, p} = LUDecompositionWithPartialPivoting[A, opts];
     {l, u} = GetLUMatrices[lu];

     (*
        Print["lu = ", Normal[lu]];
        Print["l = ", Normal[l]];
        Print["u = ", Normal[u]];
     *)

     Return[
       Check[
         UpperTriangularSolve[u, 
            LowerTriangularSolve[l, id[[p]], opts], opts]
         ,
         id
         ,
         MatrixDecompositions::Singular
       ]
     ];

  ];

  
  (* LU Decomposition with partial pivoting *)
  (* From Golub and Van Loan, p 112 *)

  LUPartialPivoting[v_?MatrixQ, f_:Abs] := LUPartialPivoting[v[[All,1]], f];

  LUPartialPivoting[v_List, f_:Abs] := Part[Ordering[f[v],-1], 1];

  LUPartialPivoting[v_SparseArray, f_:Abs] := Module[
    {rules, maxElement},

     (* Get rules *)
     rules = ArrayRules[v];

     (* Pick largest *)
     maxElement = LUPartialPivoting[rules[[All,2]], f];

     (* Return (1,1) element if matrix is zero *)
     If[ maxElement == Length[rules],
	1
       ,
	Part[rules[[maxElement]], 1, 1]
     ]

  ];

  LUDecompositionWithPartialPivoting[AA_?MatrixQ, 
                                     opts:OptionsPattern[{}]] := 
  Module[
    {options, zeroTest, pivoting, dot, rightDivide,
     suppressPivoting,
     A, m, n, p, k, N, mu, lambda},

     (* process options *)

     options = Flatten[{opts}];

     zeroTest = ZeroTest
	    /. options
	    /. Options[MatrixDecompositions, ZeroTest];

     pivoting = Pivoting
	    /. options
	    /. Options[LUDecompositionWithPartialPivoting, Pivoting];

     rightDivide = RightDivide
	    /. options
	    /. Options[MatrixDecompositions, RightDivide];

     dot = Dot
	    /. options
	    /. Options[MatrixDecompositions, Dot];

     suppressPivoting = SuppressPivoting
	    /. options
	    /. Options[MatrixDecompositions, SuppressPivoting];
      
     (* start algorithm *)

     A = AA;
     {m,n} = Dimensions[A];
     rank = Min[n,m];
     p = Range[m];
     q = Range[n];
     N = If[n >= m, rank - 1, rank];

     (*
     Print["m = ", m];
     Print["n = ", n];
     Print["N = ", N];
     *)

     For [k = 1, k <= N, k++,

       (* Print["k = ", k]; *)

       (* Pivoting *)
       If[ suppressPivoting,
           (* SuppressPivoting *)
           If[ zeroTest[A[[k,k]]],
               mu = pivoting[ A[[k ;; m, k]] ] + k - 1;
               If [ zeroTest[A[[mu,k]]],
                    (* fine to proceed *)
                    mu = 1
                   ,
                    (* incomplete factorization *)
                    Message[MatrixDecompositions::Incomplete];
                    Break[];
               ];
              ,
               mu = k;
           ]
          ,
           (* Regular Pivoting *)
           mu = pivoting[ A[[k ;; m, k]] ] + k - 1;
       ];
       (* Print["mu = ", mu]; *)

       (* Interchange rows *)
       A[[{k,mu}, All]] = A[[{mu,k}, All]];

       (* Store permutations *)
       p[[{k,mu}]] = p[[{mu,k}]];

       (* Print["p = ", p]; *)

       (* If zero pivot, skip *)
       If[ zeroTest[A[[k,k]]],
	 Continue[];
       ];

       (* Print["A- = ", Normal[A]]; *)

       (* Update matrix *)
       A[[k+1 ;; m, k]] = rightDivide[ A[[k+1 ;; m, k]], A[[k,k]] ];

       If [k < n
	   ,
	   A[[k+1 ;; m, k+1 ;; n]] -= 
	      dot[A[[k+1 ;; m, {k}]], A[[{k}, k+1 ;; n]]];
       ];

       (* Print["A+ = ", Normal[A]]; *)

    ];

    (* Print["k = ", k]; *)

    Return[{A, p}];

  ];


  (* LU Decomposition with complete pivoting *)
  (* From Golub and Van Loan, p 118 *)

  LUCompletePivoting[A_?MatrixQ, f_:Abs] := Module[
    {maxCol, maxRow},

    maxCol = Flatten[Map[LUPartialPivoting[#, f]&, A]];
    maxRow = LUPartialPivoting[
                Apply[Part[A,##]&, MapIndexed[{Part[#2,1],#1}&, maxCol], 2]
                , f];

    Return[{maxRow, maxCol[[maxRow]]}];

  ];

  LUCompletePivoting[A_SparseArray, f_:Abs] := Module[
    {rules, maxElement},

     (* Get rules *)
     rules = ArrayRules[A];

     (* Pick largest *)
     maxElement = LUPartialPivoting[rules[[All,2]], f];

     (* Return (1,1) element if matrix is zero *)
     If[ maxElement == Length[rules],
	{1,1}
       ,
	Part[rules[[maxElement]], 1]
     ]

  ];

  LUDecompositionWithCompletePivoting[AA_?MatrixQ, opts:OptionsPattern[{}]] := 
  Module[
    {options, zeroTest, pivoting, dot, rightDivide,
     suppressPivoting,
     A, m, n, rank, p, q, k, N, mu, lambda},

     (* process options *)

     options = Flatten[{opts}];

     zeroTest = ZeroTest
	    /. options
	    /. Options[MatrixDecompositions, ZeroTest];

     pivoting = Pivoting
	    /. options
	    /. Options[LUDecompositionWithCompletePivoting, Pivoting];

     rightDivide = RightDivide
	    /. options
	    /. Options[MatrixDecompositions, RightDivide];

     dot = Dot
	    /. options
	    /. Options[MatrixDecompositions, Dot];

     suppressPivoting = SuppressPivoting
	    /. options
	    /. Options[MatrixDecompositions, SuppressPivoting];

     (* Abort if SuppressPivoting is called *)
     If[ suppressPivoting,
         Message[LUDecompositionWithCompletePivoting::SuppressPivoting];
         Return[{$Failed,$Failed,$Failed,$Failed}];
     ];
      
     (* start algorithm *)

     A = AA;
     {m,n} = Dimensions[A];
     rank = Min[n,m];
     p = Range[m];
     q = Range[n];
     N = If[n >= m, rank - 1, rank];

     (*
     Print["m = ", m];
     Print["n = ", n];
     Print["N = ", N];
     *)

     For [k = 1, k <= N, k++,

       (* Print["k = ", k]; *)

       (* Pivot *)
       {mu, lambda} = pivoting[ A[[k ;; m, k ;; n]] ] + k - 1;

       (* Print["mu = ", mu, "\nlambda = ", lambda]; *)

       (* Interchange rows *)
       A[[{k,mu}, All]] = A[[{mu,k}, All]];

       (* Interchange columns *)
       A[[All, {k,lambda}]] = A[[All, {lambda,k}]];

       (* Store permutations *)
       p[[{k,mu}]] = p[[{mu,k}]];
       q[[{k,lambda}]] = q[[{lambda,k}]];

       (* Print["p = ", p, "\nq = ", q]; *)

       (* If zero pivot, terminate *)
       If[ zeroTest[A[[k,k]]],
	 rank = k - 1;
	 Break[];
       ];

       (* Print["A- = ", Normal[A]]; *)

       (* Update matrix *)
       A[[k+1 ;; m, k]] = rightDivide[ A[[k+1 ;; m, k]], A[[k,k]] ];

       If [k < n
	   ,
	   A[[k+1 ;; m, k+1 ;; n]] -= 
	      dot[A[[k+1 ;; m, {k}]], A[[{k}, k+1 ;; n]]];
       ];

       (* Print["A+ = ", Normal[A]]; *)

    ];

    (* Print["k = ", k]; *)

    If[ k > N && n >= m && zeroTest[A[[k,k]]],
       rank--;
    ];

    Return[{A, p, q, rank}];

  ];


  (* LDL Decomposition with Bunch-Parlett pivoting *)
  (* From Golub and Van Loan, p 168 *)

  LDLDecomposition[AA_?MatrixQ, opts:OptionsPattern[{}]] := 
  Module[
    {options, zeroTest, partialPivoting, completePivoting, 
     leftDivide, rightDivide, dot, inverse, selfAdjointQ,
     suppressPivoting,
     A, E, m, rank, p, k, s, i, j, l, mu0, mu1, 
     alpha = N[(1+Sqrt[17])/8]},

     (* process options *)

     options = Flatten[{opts}];

     zeroTest = ZeroTest
	    /. options
	    /. Options[MatrixDecompositions, ZeroTest];

     partialPivoting = PartialPivoting
	    /. options
	    /. Options[LDLDecomposition, PartialPivoting];

     completePivoting = CompletePivoting
	    /. options
	    /. Options[LDLDecomposition, CompletePivoting];

     rightDivide = RightDivide
	    /. options
	    /. Options[MatrixDecompositions, RightDivide];

     leftDivide = LeftDivide
	    /. options
	    /. Options[MatrixDecompositions, LeftDivide];

      dot = Dot
	    /. options
	    /. Options[MatrixDecompositions, Dot];

     inverse = Inverse
            /. options
	    /. Options[LDLDecomposition, Inverse];

     selfAdjointQ = SelfAdjointMatrixQ
	    /. options
	    /. Options[MatrixDecompositions, SelfAdjointMatrixQ];
      
     suppressPivoting = SuppressPivoting
	    /. options
	    /. Options[MatrixDecompositions, SuppressPivoting];
      
     (* start algorithm *)

     A = AA;
     {m,n} = Dimensions[A];

     (* tests *)
     If[ !selfAdjointQ[A],
         Message[MatrixDecompositions::SelfAdjoint];
         Return[{A,{},{},-1}];
     ];
      
     rank = m;
     p = Range[m];
     s = {};
     For [k = 1, k <= m - 1, k++,

       (* Print["k = ", k]; *)

       (* Pivoting *)
       If[ suppressPivoting,
           
           (* SuppressPivoting *)
           
           {i, j, l} = {k, k+1, k};
           mu1 = A[[l, l]];
           If[ zeroTest[mu1] && 
               zeroTest[A[[k+1, k]]] && 
               zeroTest[A[[k+1, k+1]]]
              ,
               (* incomplete factorization *)
               Print[A[[k;;k+1,k;;k+1]]];
               Message[MatrixDecompositions::Incomplete];
               Break[];
           ];
           (* otherwise *)
           If[ zeroTest[mu1]
              ,
               (* pivot on 2x2 block *)
               mu1 = 0; mu0 = 1;
              ,
               (* pivot on 1x1 block (l,l) *)
               mu1 = 1; mu0 = 0;
           ];
           
          ,
           
           (* Bunch-Parlett pivot strategy *)
           
           {i, j} = k - 1 + completePivoting[ A[[k ;; m, k ;; m]] ];
           l = k - 1 + partialPivoting[ Diagonal[ A[[k ;; m, k ;; m]] ]];

           mu0 = A[[i, j]];
           mu1 = A[[l, l]];
           
           If[ NumericQ[mu0] && NumericQ[mu1]
              ,
               (* If pivots are numbers *)
               {mu0, mu1} = Abs[{mu0, mu1}];
              ,
               (* If pivots are not numbers *)
               If[ zeroTest[mu1]
                  ,
                   (* pivot on 2x2 block *)
                   mu1 = 0; mu0 = 1;
                  ,
                   (* pivot on 1x1 block (l,l) *)
                   mu1 = 1; mu0 = 0;
               ];
           ];

       ];

       (*
         Print["i = ", i];
         Print["j = ", j];
         Print["l = ", l];
         Print["mu0 = ", mu0];
         Print["mu1 = ", mu1];
         Print["alpha mu0 = ", alpha mu0];
       *)

       If[ mu1 >= alpha mu0,

	 (* P1 => s = 1 and |e11| = mu1 *)

	 AppendTo[s, 1];

	 (* Print["s = ", s]; *)

	 (* Interchange rows *)
	 A[[{k,l}, All]] = A[[{l,k}, All]];

	 (* Interchange columns *)
	 A[[All, {k,l}]] = A[[All, {l,k}]];

	 (* Store permutations *)
	 p[[{k,l}]] = p[[{l,k}]];

	 (* Print["p = ", p]; *)

	 (* If zero pivot, terminate *)
	 If[ zeroTest[A[[k,k]]],
	   rank = k - 1;
	   Break[];
	 ];

	 (* Print["A- = ", MatrixForm[A]]; *)

	 (* Update matrix *)
         A[[k+1;;m, k]] = rightDivide[ A[[k+1;;m, k]], A[[k,k]] ];
           
         A[[k+1;;m, k+1;;m]] -= dot[ A[[k+1;;m, {k}]],
                                     A[[{k}, k+1;;m]] ];

         A[[k, k+1;;m]] = leftDivide[ A[[k,k]], A[[k, k+1;;m]] ];
           
         (* Print["A+ = ", MatrixForm[A]]; *)

	 ,

	 (* P1 => s = 2 and |e21| = mu0 *)

	 AppendTo[s, 2];

	 (* Print["s = ", s]; *)

	 (* Interchange rows *)
	 A[[{k,i}, All]] = A[[{i,k}, All]];

	 (* Interchange columns *)
	 A[[All, {k,i}]] = A[[All, {i,k}]];

	 (* Interchange rows *)
	 A[[{k+1,j}, All]] = A[[{j,k+1}, All]];

	 (* Interchange columns *)
	 A[[All, {k+1,j}]] = A[[All, {j,k+1}]];

	 (* Store permutations *)
	 p[[{k,i}]] = p[[{i,k}]];
	 p[[{k+1,j}]] = p[[{j,k+1}]];

	 (* Print["p = ", p]; *)

	 (* If zero pivot, terminate *)
	 If[ zeroTest[A[[k+1,k]]],
	   rank = k - 1;
	   Break[];
	 ];

         (* If k = m - 1, terminate *)
         If [k == m - 1,
           Break[];
         ];
           
	 (* Print["A- = ", MatrixForm[A]]; *)

	 (* Update matrix *)
	 E = A[[k;;k+1, k;;k+1]];
	 A[[k+2;;m, k;;k+1]] = dot[ A[[k+2;;m, k;;k+1 ]],
                                    inverse[E] ];

         A[[k+2;;m, k+2;;m]] -= dot[ A[[k+2;;m, k;;k+1 ]],
                                     A[[k;;k+1, k+2;;m ]] ];

         A[[k;;k+1, k+2;;m]] = dot[ inverse[E], A[[k;;k+1 , k+2;;m]] ];

	 (* 
         Print["E = ", MatrixForm[E]];
	 Print["A+ = ", MatrixForm[A]];
         *)

	 (* Increment k *)
	 k++;

       ];

    ];

    (* Print["k = ", k]; *)
      
    If[ k == m,
       AppendTo[s, 1];
       If [zeroTest[A[[k,k]]],
         rank--;
       ];
    ];

    Return[{A, p, s, rank}];

  ];

End[]

EndPackage[]
