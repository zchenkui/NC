(* :Title: 	PrimalDualEmbedding.m *)

(* :Author: 	Mauricio de Oliveira *)

(* :Context: 	PrimalDual` *)

(* :Summary: *)

(* :Alias:   *)

(* :Warnings: *)

(* :History: *)

BeginPackage[ "PrimalDual`",
 	      "NesterovTodd`",
              "Kronecker`",
              "MatrixVector`",
              "CG`",
              "RationalApproximate`",
              "NCDebug`" 
]

Clear[PrimalDual];
PrimalDual::usage = "Solve semidefinite program using a primal dual method";

Clear[
  Direct, CG,
  NT, KSH, KSHDual, AHO,
  ShortStep, LongStep, PredictorCorrector, Profiling,
  SparseWeights
]

Options[PrimalDual] = {
  SearchDirection -> NT,
  Method -> PredictorCorrector,
  LeastSquares -> Direct,
  LeastSquaresSolver -> Null,
  LeastSquaresSolverFactored -> Null,
  GapTol -> 10.^(-9),
  FeasibilityTol -> 10.^(3) * GapTol,
  MaxIter -> 250,
  CGTol -> 10.^(-3),
  CGMaxIter -> Infinity,
  CGPreconditioner -> Diagonal,
  ScaleHessian -> True,
  SparseWeights -> True,
  RationalizeIterates -> False,
  RationalizeTol -> GapTol,
  SymmetricVariables -> {},
  DebugLevel -> 0,
  PrintSummary -> True,
  PrintIterations -> True,
  Profiling -> False
};

Begin[ "`Private`" ]

  Clear[dualToVector];
  dualToVector[x_, sym_] := 
    If[ sym, SymmetricToVector[x, 1], ToVector[x] ];

  Clear[primalToVector];
  primalToVector[x_, sym_] := 
    If[ sym, SymmetricToVector[x, 2], ToVector[x] ];

  Clear[reshape];
  reshape[v_, dims_, syms_] := Module[
    { mdims, start, end, matrices },

    (* Determine vector dimensions *)
    mdims = MapThread[
       If[ #2, #1[[1]]*(#1[[1]]+1)/2, Times @@ #1 ]&, 
       {dims, syms}];

    (* mdims = Apply[Times, dims, 2]; *)

    (* Determine start points *)
    start = Drop[FoldList[Plus, 0, mdims], -1] + 1;

    (* Determine end points *)
    end = start + mdims - 1;

    (* NCDebug[1, mdims, start, end]; *)

    matrices = MapThread[
        If[ #3, ToSymmetricMatrix[#1,#2], ToMatrix[#1,#2] ]&, 
      	{ MapThread[Take[v,{#1,#2}]&, {start, end}],
          Part[dims, All, 1],
	  syms }];

    (*
      matrices = MapThread[
          ToMatrix[#1,#2]&, 
      	  { MapThread[Take[v,{#1,#2}]&, {start, end}],
            Part[dims, All, 1] }];
    *)

    (* NCDebug[1, matrices ]; *)

    Return[ matrices ];

  ];

  Clear[inner];
  inner[x_, y_] := Total[MapThread[Total[Flatten[#1*#2]]&, {x, y}]];

  Clear[maxEig];
  maxEig[x_] := Part[Eigenvalues[x, 1], 1] /; Length[x] <= 100;
  maxEig[x_] := 
  Part[
    Quiet[
      Eigenvalues[x, 1, 
                  Method -> {"Arnoldi", 
                             Tolerance -> 10.^(-4),
	                     MaxIterations -> 100}]
     ,
      Eigenvalues::maxit2 ]
   , 1];

  Clear[minEig];
  minEig[x_] := Min[Eigenvalues[x]] /; Length[x] <= 100;
  minEig[x_] := Module[
    {shift = Abs[maxEig[x]]},
    Return [ 
      Part[
        Quiet[
          Eigenvalues[x, -1, 
            Method -> {"Arnoldi", 
	               Tolerance -> 10.^(-4), 
		       Shift -> -1.2*shift,
		       MaxIterations -> 100}]
         ,
	  Eigenvalues::maxit2]
      , 1]
    ];
  ];

  PrimalDual[
    FPrimalEval_, FDualEval_, 
    SylvesterVecEval_, SylvesterVecDiagonalEval_, 
    BB_, CC_,
    opts___Rule:{}
  ] := 
    Module[ 
      {  counter = 0,  (* number of outer iterations *)
         delta = 4/10,
         gamma = 95/100,
         sigma = 3/10,
         leastSquares, 
         leastSquaresSolver, 
	 method,
         maxIter,
         (* options *)
         options, 
	 profiling, sparseWeights, 
	 rationalizeIterates, rationalizeTol,
	 feasibilityTol,
	 symmetricVariables, syms,
         (* local variables *)
         dimcc, dimbb, dimy, numcons, nn, totaldimx,
	 Pk, pk, Pktau, Pktheta,
	 LktSolve, RktSolve,
	 primalFeasRadius, dualFeasRadius, dualFeasMargin,
	 primalFeasible, dualFeasible,
	 (* performance *)
	 cgK, iters = {}
      },

    (* Process options *)
    options = Flatten[{opts}];

    profiling = Profiling
          /. options
	  /. Options[PrimalDual, Profiling];

    sparseWeights = SparseWeights
          /. options
	  /. Options[PrimalDual, SparseWeights];

    rationalizeIterates = RationalizeIterates
          /. options
	  /. Options[PrimalDual, RationalizeIterates];

    rationalizeTol = RationalizeTol
          /. options
	  /. Options[PrimalDual, RationalizeTol]
          /. options
	  /. Options[PrimalDual, GapTol];

    feasibilityTol = FeasibilityTol
          /. options
	  /. Options[PrimalDual, FeasibilityTol]
          /. options
	  /. Options[PrimalDual, GapTol];

    scaleHessian = ScaleHessian
          /. options
          /. Options[PrimalDual, ScaleHessian];

    leastSquares = LeastSquares
          /. options
          /. Options[PrimalDual, LeastSquares];

    leastSquaresSolver = LeastSquaresSolver
          /. options
          /. Options[PrimalDual, LeastSquaresSolver];

    leastSquaresSolverFactored = LeastSquaresSolverFactored
          /. options
          /. Options[PrimalDual, LeastSquaresSolverFactored];

    searchDirection = SearchDirection
          /. options
          /. Options[PrimalDual, SearchDirection];

    method = Method
          /. options
          /. Options[PrimalDual, Method];

    gapTol = GapTol
          /. options
          /. Options[PrimalDual, GapTol];

    maxIter = MaxIter
          /. options
          /. Options[PrimalDual, MaxIter];

    cgTol = CGTol
          /. options
          /. Options[PrimalDual, CGTol];

    cgMaxIter = CGMaxIter
          /. options
          /. Options[PrimalDual, CGMaxIter];
    cgK = cgMaxIter;

    cgPreconditioner = CGPreconditioner
          /. options
          /. Options[PrimalDual, CGPreconditioner];

    symmetricVariables = SymmetricVariables 
          /. options
          /. Options[PrimalDual, SymmetricVariables];

    printSummary  = PrintSummary
          /. options
          /. Options[PrimalDual, PrintSummary];

    printIterations  = PrintIterations
          /. options
          /. Options[PrimalDual, PrintIterations];
        
    debugLevel = DebugLevel
          /. options
          /. Options[PrimalDual, DebugLevel];

    SetOptions[NCDebug, DebugLevel -> debugLevel];

    (* get block dimensions of CC and BB *)
    dimcc = MatrixVectorBlockDimensions[CC];
    dimbb = MatrixVectorBlockDimensions[BB]; 

    (* dimensions of Y blocks *)
    mi = MatrixVectorDimensions[BB];

    (* total dimension of X and S, for calculating dual gap muk *)
    n = Total[Flatten[dimcc]] / 2; 

    (* calculate number of variables *)
    numvars = Apply[Plus, Apply[Times,mi,1]]; (* number of scalar variables *)
    numcons = Length[CC]; (* number of constraints*)

    (* process symmetric variables *)
    syms = Table[ False, {i, Length[BB]}];
    Part[ syms, symmetricVariables ] = True;

    NCDebug[ 2, syms ];

    NCDebug[ 2, 
             dimcc, dimbb, mi, n, numcons ];

    (* initialization *)
    EyeCC = MatrixVectorPartition[
    	      Map[IdentityMatrix[Part[#,1]]&, MatrixVectorDimensions[CC]],
            dimcc];
    Y0 = Apply[ConstantArray[0, {#1,#2}]&, dimbb, 2];
    X0 = EyeCC;
    tau0 = 1;
    theta0 = 1;
    rho0 = 1;
    
    (* make Xk in the same structure as CC *)
    Xk = X0;
    Yk = Y0;
    Ski = Sk = Xk;
    tauk = tau0;
    thetak = theta0;
    rhok = rho0;

    NCDebug[ 3, 
             Yk, Xk, Sk ];

    dY0 = Y0;
    dY0tau = Y0;
    dY0theta = Y0;
    
    (* auxiliary matrices Bbar and Cbar *)
    BBbar = BB - (FPrimalEval @@ Xk);
    CCbar = CC - (FDualEval @@ Yk) - Sk;

    If [ rationalizeIterates,
      BBbar = RationalApproximate[BBbar, rationalizeTol];
      CCbar = RationalApproximate[CCbar, rationalizeTol];
     , 
      (* otherwise make sure everybody is floating point! *)
      Xk *= 1.;
      Yk *= 1.;
      Sk *= 1.;
      Ski *= 1.;
      tauk *= 1.;
      thetak *= 1.;
      rhok *= 1.;
    ];

    NCDebug[ 3, 
             BBbar, CCbar ];

    zbar = 1 
    	 + inner[CC,EyeCC] 
	 - inner[BB,Yk];
    beta = n + 1;

    NCDebug[ 2, 
             zbar, beta ];

    (* augmented system dimenstions *)
    NN = n + 1;

    Switch [ method, 
        ShortStep, 

	(* short step algorithm *)
        sigmak = RationalApproximate[N[1 - delta / Sqrt[NN]], gapTol];

	, 
	LongStep,
	
        (* long step algorithm *)
        sigmak = sigma;

    ];

    (* calculate initial dual gap *)
    mu0 = (Total[MapThread[Total[Flatten[#1*#2]]&, {Xk, Sk}]] + tauk*rhok) / NN;
    muk = mu0;

    NCDebug[ 2, 
             mu0 ];

    (* neighborhoods *)
    mukiXkSk = MatrixVectorDot[Xk, Sk] / muk;
    N2 = Sqrt[
	   MatrixVectorFrobeniusNorm[mukiXkSk - EyeCC]^2 
         + (tauk*rhok/muk - 1)^2];

    Noo = Min[Min[MatrixVectorEigenvalues[mukiXkSk]], tauk*rhok/muk];

    Dmoo = muk 
      - Min[Min[MatrixVectorEigenvalues[MatrixVectorDot[Xk, Sk]]], tauk*rhok];

    NCDebug[ 2, 
             N2, Noo, Dmoo ];
	              
    (* Print Header *)

    If[ printSummary,

      Print[" Problem data:"];
      Print[" * Dimensions (total):"];
      Print["   - Variables             = ", numvars ];
      Print["   - Inequalities          = ", numcons ];
      Print[" * Dimensions (detail):"];
      Print["   - Variables             = ", mi ];
      Print["   - Inequalities          = ", Part[MatrixVectorDimensions[CC], All,1] ];
      Print["\n Method:"];
      Print[" * Method                  = ", method];
      Print[" * Search direction        = ", searchDirection];
      Print["\n Precision:"];
      Print[" * Gap tolerance           = ", ScientificForm[gapTol]];
      Print[" * Feasibility tolerance   = ", ScientificForm[feasibilityTol]];
      Print[" * Rationalize iterates    = ", rationalizeIterates,
        If[ rationalizeIterates, 
            SequenceForm["\t(tol = ", ScientificForm[rationalizeTol], ")" ],
            "" ]];
      If [ leastSquares === CG,
        Print["\n CG Options:"];
        Print[" * CG tolerance            = ", ScientificForm[cgTol]];
        Print[" * CG maximum # iterations = ", ScientificForm[cgMaxIter]];
        Print[" * CG preconditioner       = ", cgPreconditioner];
      ];
      Print["\n Other options:"];
      Print[" * Debug level             = ", debugLevel];

      Print[""];

    ];

    If [ printIterations, 
      (* Print Header *)

      If[ leastSquares === CG, 
        Print["                                                                        ",
              " Conj Grad"];
        Print["                                                                        ",
              "-----------"];
      ];

      Print["  K     <B, Y>         mu  theta/tau      alpha",
      	    "     |X S|2    |X S|oo ",
            " |A* X-B|   |A Y+S-C|",
            If[ leastSquares === CG, "      #      res", "" ]
      ];
      Print[" -----------------------------------------------------",
            "--------------------------------------",
            If[ leastSquares === CG, "-----------------", "" ]
      ];
    ];

    (* If[ searchDirection === NT, *)

      NCDebug[ 1, "* Initializing NT computations"];

      (* initial Rk and RkSolve for calculating W *)
      plnSk = MatrixVectorBlockMatrix[Sk];
      plnXk = MatrixVectorBlockMatrix[Xk];

      (* R^T R = S *)
      Rk = Map[CholeskyDecomposition, plnSk];
      Rkt = Map[ Transpose, Rk ];
      tRktSolve = Map[ LinearSolve, Rkt ];
      RktSolve = MapThread[ #1[#2]&, {tRktSolve, #} ]&;

      (* L^T L = X *)
      Lk = Map[CholeskyDecomposition, plnXk];
      Lkt = Map[ Transpose, Lk ];
      tLktSolve = Map[ LinearSolve, Lkt ];
      LktSolve = MapThread[ #1[#2]&, {tLktSolve, #} ]&;

      NCDebug[ 4, plnSk, plnSk, Rk, Lk ];

    (* ]; *)
     
    (* start of the numerical search *)
    success = True;
    While[ (muk > gapTol && counter < maxIter),

      NCDebug[ 2, counter ];

      (*
      If[ rationalizeIterates,
        muk = RationalApproximate[muk, rationalizeTol];
        Ski = RationalApproximate[Ski, rationalizeTol];

        NCDebug[ 2, 
	         muk];
      ];
      *)

      timeSD = Timing[

        Switch [ searchDirection,

          (* Nesterov-Todd direction *)

          NT, 

            NCDebug[ 1, "* Computing NT search direction"];

            (* Calculate Wk *)
            {plnWk, Gk, dk} = NesterovToddScaling[ Rk, Lk ];

            (* Wk WkT into block-structured matrix*)
            Wk = MatrixVectorPartition[plnWk, dimcc];
            Wkr = Wkl = If[ sparseWeights
                           ,Map[SparseArray, Wk]
                           ,Wk
                        ];
 
            NCDebug[ 3, 
                     plnWk, Wk ];

            NCDebug[ 2, 
                     Min[MatrixVectorEigenvalues[Wk]] ];
 
          (* HRVM/KSH/M Direction *)
          , KSH, 

            NCDebug[ 1, "* Computing HRVM/KSH/M search direction"];

            Wkl = Xk;
	    Wkr = Ski;

          , KSHDual, 

            NCDebug[ 1, "* Computing HRVM/KSH/M dual search direction"];

	    Wkl = Ski;
  	    Wkr = Xk;

        ];

      ];

      If[ profiling, Print["> Scaling = ", timeSD[[1]]] ];

      If [ leastSquaresSolver === Null,

         (* start default least squares solver *)

         timeHessianAssembly = Timing[

               NCDebug[ 1, "*   Assembling Hessian"];

               Hk = ArrayFlatten[SylvesterVecEval @@ {Wkl, Wkr}];

               NCDebug[ 2, 
                        Norm[Hk-Transpose[Hk]] ];

               (* Symmetrize Hk *)
               Hk = (Hk + Transpose[Hk])/2;

               NCDebug[ 3, 
                        Eigenvalues[Hk], Min[Eigenvalues[Hk]] ];

               NCDebug[ 3, 
	                Hk ];
      
               NCDebug[ 1, "*   Scaling Hessian"];

               If [ (!rationalizeIterates) && scaleHessian, 

                    (* Hessian diagonal scaling *)
                    HkSqrtDiag = Tr[Hk, List];

                    If [ Min[HkSqrtDiag] <= 0, 
                         NCDebug[ 0, "Hessian is no longer positive definite!" ]; 
			 success = False;
                         Break[];
                    ];
                    HkSqrtDiag = Sqrt[HkSqrtDiag];

                    Hk = Transpose[Hk / HkSqrtDiag] / HkSqrtDiag;

                   , 

                    HkSqrtDiag = 1;
	      ];

              NCDebug[ 2, HkSqrtDiag ];

         ];

         If [ profiling, Print["> Hessian Assembly = ", timeHessianAssembly[[1]]] ];

         timeFactorization = Timing [

             NCDebug[ 1, "*   Factoring Hessian"];

             Check[

                tHkSolve = LinearSolve[Hk, Method -> "Cholesky"];

               ,

                NCDebug[ 0, 
                         "WARNING: Could not factor Hessian!" ];
 		success = False;
                Break[];

             ];

             NCDebug[ 2, Head[tHkSolve] ];

             Check[

                If [ Head[tHkSolve] =!= LinearSolveFunction,
                     tHkSolve = LinearSolve[Hk];
                ];

               ,

                NCDebug[ 0, 
                         "WARNING: Could not factor Hessian!" ];

                If [ counter == 0,
                     NCDebug[ 0, 
                              "SDP most likely contain linearly dependent columns or is unbounded.",
			      "Try adding additional constraints." ];
     		     success = False;
                     Break[];
                ];

             ];

             NCDebug[ 2, Head[tHkSolve] ];

             HkSolve = If [ HkSqrtDiag === 1, 
                            tHkSolve
                           , 
			   (tHkSolve[# / HkSqrtDiag] / HkSqrtDiag)&
	     ];

         ];

         If [ profiling, Print["> Hessian Factorization = ", timeFactorization[[1]]] ];


      ];

      timePredictor = Timing [      

           NCDebug[ 1, "* Computing RHS of (Predictor) Sylvester equation"];

           (* calculate RHS of Predictor Sylvester equation *)
           If[ method === PredictorCorrector, 
               Pk = Xk;
	       pk = rhok;
              ,
	       Pk = Xk - sigmak * muk * Ski;
	       pk = rhok - sigmak*muk/tauk;
 	   ];
           Pktau = MapThread[Dot, {Wkl, CC, Wkr}];
           Pktau = (Pktau + Map[Transpose, Pktau])/2; 

           Pktheta = MapThread[Dot, {Wkl, CCbar, Wkr}];
           Pktheta = (Pktheta + Map[Transpose, Pktheta])/2; 

           If[ rationalizeIterates,
               pk = RationalApproximate[pk, rationalizeTol];
               Pk = RationalApproximate[Pk, rationalizeTol];
               Pktau = RationalApproximate[Pktau, rationalizeTol];
               Pktheta = RationalApproximate[Pktheta, rationalizeTol];
           ];

	   (* 
	      CGLS[F, G, h1, h2, x0]

	      G -> A^* = FPrimalEval
	      F -> (1/2) (E A F + F A E) = Wk FDualEval Wk
	      h1 -> Pk
	      h2 -> 0

              ( * Run conjugate gradient * )

              {ddYk, {cgRes, cgK}} = 
              CGLS[ MatrixVectorDot[Wkl, FDualEval @@ ##, Wkr]&, 
                    (FPrimalEval @@ ##)&, 
 	   	    Pk, 0*BB, 
	   	    dY0, 
                    10.^(-4), 1000, inner, Identity, True, 10
              ];

 	   *)

          NCDebug[ 1, "*   Flatten right hand sides"];

          (* computing Vec(Pk)*)
          gk = Flatten[MapThread[primalToVector, 
                                 {FPrimalEval @@ Pk, syms}]];
          gktau = Flatten[MapThread[primalToVector, 
                                 {(FPrimalEval @@ Pktau) + BB, syms}]];
          gktheta = Flatten[MapThread[primalToVector,
 	                         {-((FPrimalEval @@ Pktheta) + BBbar), syms}]];

          NCDebug[ 3, 
	           gk, gktau, gktheta ];

          NCDebug[ 1, "*   Computing (predictor) search direction"];

          If [ leastSquaresSolver === Null,

	        timeSolve = Timing [

                    dyk = HkSolve[gk];
                    dyktau = HkSolve[gktau];
                    dyktheta = HkSolve[gktheta];

                    NCDebug[ 3, 
	                     dyk, dyktau, dyktheta ];

                    (* Residuals *)
		    (* 
                      resk = (Hk . (dyk * HkSqrtDiag)) * HkSqrtDiag - gk ;
                      resktau = (Hk . (dyktau  * HkSqrtDiag)) * HkSqrtDiag - gktau;
                      resktheta = (Hk . (dyktheta  * HkSqrtDiag)) * HkSqrtDiag - gktheta;

                      NCDebug[ 0, 
                               Norm[resk], Norm[resktau], Norm[resktheta] ];
 		     *)

	        ];

		If [ profiling, Print["> > Predictor Solution = ", timeSolve[[1]]] ];

	  ,
  
                NCDebug[ 1, "*     Invoking custom linear algebra solver"];

                (* start custom least squares solver *)

                timeCLS = Timing [

		    Check[

      	                {dyk, dyktau, dyktheta} 
	                    = leastSquaresSolver @@ {Wkl, Wkr, {gk, gktau, gktheta}};

	               ,

                        NCDebug[ 0, 
                                 "WARNING: Could not factor Hessian!" ];
			success = False;
			Break[];

			(*,
		       
			 CholeskyDecomposition::posdef *)

		    ];

                ];

                If[ profiling, Print["> > Custom Least Squares  = ", timeCLS[[1]]] ];

                (* end custom least squares solver *)

	  ];

          NCDebug[ 1, "*   Reshaping (predictor) search directions"];

          timeReshape = Timing [
		   
              (* Direction dYk from dyk *)
              dYk = reshape[dyk, mi, syms];
              dYktau = reshape[dyktau, mi, syms];
              dYktheta = reshape[dyktheta, mi, syms];

              (* NCDebug[0, MatrixVectorFrobeniusNorm[ddYk-dYk]]; *)

          ];

          If[ profiling, Print["> > Reshape  = ", timeReshape[[1]]] ];

          timeDual = Timing [

              NCDebug[ 1, "*   Computing (predictor) dual search directions"];

              (* Compute dXk *)
              dXk = MapThread[ Dot, {Wkl, FDualEval @@ dYk, Wkr}] - Pk;
              dXktau = MapThread[ Dot, {Wkl, FDualEval @@ dYktau, Wkr}] - Pktau;
              dXktheta = MapThread[ Dot, {Wkl, FDualEval @@ dYktheta, Wkr}] + Pktheta;

              (* Symmetrize dXk *)
              dXk = (dXk + Map[Transpose, dXk])/2; 
              dXktau = (dXktau + Map[Transpose, dXktau])/2; 
              dXktheta = (dXktheta + Map[Transpose, dXktheta])/2; 

          ];

          (* Primal Predictor Residuals *)
	  (* 
            res1 = - FPrimalEval @@ dXk;
            res2 = - (FPrimalEval @@ dXktau) + BB;
            res3 = - (FPrimalEval @@ dXktheta) - BBbar;
            NCDebug[ 0,
       	             Map[Norm, res1],
       	             Map[Norm, res2],
      	             Map[Norm, res3] ];
          *)

          If[ profiling, Print["> > Dual directions = ", timeDual[[1]]] ];

          NCDebug[ 1, "*   Completing augmented linear system for the embedding"];

          timeEmbeddingHessianAssembly = Timing [

	      (* Assemble embedding Hessian *)
              HHk = -{{rhok/tauk, zbar},{zbar, 0}};
    	      HHk[[1,1]] = HHk[[1,1]] 
              		 - inner[BB,dYktau] 
        		 + inner[CC,dXktau];
    	      HHk[[1,2]] = HHk[[1,2]] 
              		 - inner[BB,dYktheta] 
 			 + inner[CC,dXktheta];
    	      HHk[[2,1]] = HHk[[2,1]] 
              		 - inner[BBbar,dYktau]
			 + inner[CCbar,dXktau];
    	      HHk[[2,2]] = HHk[[2,2]]
              		 - inner[BBbar,dYktheta] 
			 + inner[CCbar,dXktheta];

              HHkSqrtDiag = If [ (!rationalizeIterates) && scaleHessian, 
       	                         Sqrt[Abs[Tr[HHk, List]]]
                                , 
                                 1 ];

              NCDebug[ 2, 
	               HHk, HHkSqrtDiag ];

    	      tHHkSolve = LinearSolve[
                  Transpose[Transpose[HHk / HHkSqrtDiag] / HHkSqrtDiag]];

              NCDebug[ 2, 
	               tHHkSolve ];

              HHkSolve = If [ HHkSqrtDiag === 1, 
                              tHHkSolve
                             ,
                              (tHHkSolve[# / HHkSqrtDiag] / HHkSqrtDiag)&
              ];

	      NCDebug[ 2, 
		       HHkSolve ];

          ];

          If[ profiling, Print["> > Embedding Hessian Assembly = ", timeEmbeddingHessianAssembly[[1]]] ];

          timeEmbeddingSolve = Timing [

	        ggk = {pk, 0};
		ggk[[1]] = ggk[[1]] 
		        + inner[BB,dYk] 
			- inner[CC,dXk];
                ggk[[2]] = ggk[[2]] 
		        + inner[BBbar,dYk] 
			- inner[CCbar,dXk];

		NCDebug[ 2, 
		         ggk ];

                {dtauk, dthetak} = HHkSolve[ggk];

		NCDebug[ 2, 
		         dtauk, dthetak ];

		(* Compute residuals *)
 		(* 
 	        restauthetak = HHk . {dtauk, dthetak} - ggk;
     
		NCDebug[ 2, 
		         Norm[restauthetak] ];
	        *)

          ];

	  If[ profiling, Print["> > Embedding Solve = ", timeEmbeddingSolve[[1]]] ];

          NCDebug[ 1, "*   Computing final (predictor) search directions"];

 	  timeSearchDirections = Timing [

	       (* Compute final search directions *)
     	       dYk = dYk + dYktau * dtauk + dYktheta * dthetak;
     	       dXk = dXk + dXktau * dtauk + dXktheta * dthetak;
     	       dSk = CC * dtauk - CCbar * dthetak - (FDualEval @@ dYk);
               dSk = (dSk + Map[Transpose, dSk])/2; 
     	       drhok = inner[BB,dYk] 
               	     - inner[CC,dXk] 
		     + dthetak * zbar;

	       NCDebug[ 2, 
	       		dYk, dSk, dXk, drhok ];

	       NCDebug[ 2, 
     	       		MatrixVectorFrobeniusNorm[dXk], 
	      		MatrixVectorFrobeniusNorm[dSk],
	      		MatrixVectorFrobeniusNorm[dYk] ];

   	  ];

     	  If[ profiling, Print["> > Search directions = ", timeSearchDirections[[1]]] ];

          (* Predictor Residuals *)
	  (*
	    predRes1 = (FPrimalEval @@ dXk) - dtauk * BB + dthetak * BBbar;
            predRes2 = - inner[ BBbar, dYk] + inner[ CCbar, dXk] - dtauk * zbar;

            NCDebug[ 0,
      	       	     Map[Norm, predRes1], predRes2 ];
           *)

      ];

      If[ profiling, Print["> Predictor = ", timePredictor[[1]]] ];

      If [ method === PredictorCorrector,

           NCDebug[ 1, "* Computing corrector"];

           NCDebug[ 1, "*   Computing centering parameter"];

           timeCentering = Timing[

	       dXkScaled = LktSolve[dXk];
	       dXkScaled = Map[ Transpose, dXkScaled ];
	       dXkScaled = LktSolve[dXkScaled];
	       dXkScaled = dXkScaled + Map[ Transpose, dXkScaled ];

	       NCDebug[ 3, 
	       		Map[Min[Eigenvalues[#]]&, dXkScaled], 
			Map[minEig, dXkScaled] ];

	       lambdaDX = Min[ Map[minEig, dXkScaled] ];
	       alphaDX = If [ lambdaDX >= 0, 1, Min[1, - 2 * 0.9995 / lambdaDX] ];

	       dSkScaled = RktSolve[dSk];
	       dSkScaled = Map[ Transpose, dSkScaled ];
	       dSkScaled = RktSolve[dSkScaled];
	       dSkScaled = dSkScaled + Map[ Transpose, dSkScaled ];

	       NCDebug[ 3, 
	       		Map[Min[Eigenvalues[#]]&, dSkScaled], 
			Map[minEig, dSkScaled] ];

	       lambdaDS = Min[ Map[minEig, dSkScaled] ];
	       alphaDS = If [ lambdaDS >= 0, 1, Min[1, - 2 * 0.9995 / lambdaDS]];

               alphaTau = If [ dtauk >= 0, 1, Min[1, - 0.9995 * tauk / dtauk] ];
               alphaRho = If [ drhok >= 0, 1, Min[1, - 0.9995 * rhok / drhok] ];

               alphaAff = Min[ alphaDX, alphaDS, alphaTau, alphaRho ];

	       muAff = ( inner[Xk + alphaAff * dXk, Sk + alphaAff * dSk]
 			 + (tauk + alphaAff * dtauk)*(rhok + alphaAff * drhok) )
			 / NN;

                (* dynamic sigma *)
		sigmakk = (muAff / muk)^3;

		NCDebug[ 3,
			 lambdaDX, alphaDX, lambdaDS, alphaDS, alphaTau, alphaRho];

		NCDebug[ 2,
			 alphaAff, muAff, sigmakk];

      	   ];

      	   If[ profiling, Print["> Centering = ", timeCentering[[1]]] ];

           timeCorrector = Timing[

                 NCDebug[ 1, "*   Computing corrector term"];

	         (* Compute corrector term *)

	         Kk = Switch [ searchDirection,

		              (* Nesterov-Todd direction *)

        		      NT, 

			      (* Calculate Kk *)
			      NesterovToddCorrector[ dXk, dSk, Gk, dk ]

                             ,

			      KSH,

			      (* Calculate Kk *)
			      MapThread[Dot, {dXk, dSk, Ski} ]

                 ];

		 (* Symmetrize Kk *)
        	 Kk = (Kk + Map[Transpose, Kk]) / 2;

	    	 NCDebug[ 2,
  			  Kk ];

	         (* Compute corrector direction *)
  	         Pk = Xk - sigmakk * muk * Ski + Kk;
	         pk = rhok - sigmakk * muk / tauk + dtauk * drhok / tauk;

           	 If[ rationalizeIterates,
               	     pk = RationalApproximate[pk, rationalizeTol];
               	     Pk = RationalApproximate[Pk, rationalizeTol];
		 ];

          	 (* computing Vec(Pk)*)
          	 gk = Flatten[MapThread[primalToVector, 
		                       {(FPrimalEval @@ Pk), syms}]];

		 NCDebug[ 2, 
	           	  gk ];

                 NCDebug[ 1, "*   Computing corrector search direction"];

	         If [ leastSquaresSolverFactored === Null,

		      dyk = HkSolve[gk];

                      (* Residuals *)
		      (* 
                        resk = Hk . dyk - gk;
 
		        NCDebug[ 2, 
                                 Norm[resk] ];
		      *)

		    ,

                      timeCLS = Timing [

    	                {dyk} = leastSquaresSolverFactored @@ {{gk}};

               	      ];

                      If[ profiling, Print["> > Custom Least Squares  = ", timeCLS[[1]]] ];

	         ];

                 NCDebug[ 1, "*   Reshaping (corrector) search directions"];

	   	 (* Direction dYk from dyk *)
                 dYk = reshape[dyk, mi, syms];

	         NCDebug[ 2, 
                          dYk ];

                 NCDebug[ 1, "*   Computing (corrector) dual search directions"];

       		 (* Compute dSk *)
              	 dSk = FDualEval @@ dYk;
              	 dSk = (dSk + Map[Transpose, dSk])/2; 

              	 (* Compute dXk *)
              	 dXk = MapThread[Dot, {Wkl, dSk, Wkr}] - Pk;
              	 dXk = (dXk + Map[Transpose, dXk])/2; 

		 (* Compute embedding corrector *)
	         ggk = {pk, 0};
		 ggk[[1]] = ggk[[1]] 
		    	  + inner[BB,dYk] 
			  - inner[CC,dXk];
                 ggk[[2]] = ggk[[2]] 
		          + inner[BBbar,dYk] 
			  - inner[CCbar,dXk];

                 {dtauk, dthetak} = HHkSolve[ggk];

		 NCDebug[ 2, 
		          dtauk, dthetak ];

 		 (* Compute residuals *)
 		 (* 
		    restauthetak = HHk . {dtauk, dthetak} - ggk;
     
		    NCDebug[ 2, 
		             Norm[restauthetak] ];
		 *)

                 NCDebug[ 1, "*   Computing final (corrector) search direction"];

	         (* Compute final corrector directions *)
     	         dYk = dYk + dYktau * dtauk + dYktheta * dthetak;
     	         dXk = dXk + dXktau * dtauk + dXktheta * dthetak;
     	         dSk = CC * dtauk - CCbar * dthetak - (FDualEval @@ dYk);
		 dSk = (dSk + Map[Transpose, dSk])/2; 
		 drhok = inner[BB,dYk] 
               	       - inner[CC,dXk] 
		       + dthetak * zbar;

	         NCDebug[ 2, 
	       		  dYk, dSk, dXk, drhok ];

      	   ];

      	   If[ profiling, Print["> Corrector = ", timeCorrector[[1]]] ];

      ];

      (* Corrector Residuals *)
      (*
        res1 = (FPrimalEval @@ dXk) - dtauk * BB + dthetak * BBbar;
        res4 = - inner[ BBbar, dYk] + inner[ CCbar, dXk] - dtauk * zbar;
        NCDebug[ 0,
                 Map[Norm, res1], res4 ];
      *)

      timeLineSearch = Timing[

          NCDebug[ 1, "* Starting line search."];

       	  dXkScaled = LktSolve[dXk];
    	  dXkScaled = Map[ Transpose, dXkScaled ];
	  dXkScaled = LktSolve[dXkScaled];
	  dXkScaled = dXkScaled + Map[ Transpose, dXkScaled ];

(*
	  alphaDX = Min[1, - 2 * 0.9995 / Min[ Map[minEig, dXkScaled] ]];
          If [ alphaDX < 0, alphaDX = 1 ];
*)

          lambdaDX = Min[ Map[minEig, dXkScaled] ];
	  alphaDX = If [ lambdaDX >= 0, 1, Min[1, - 2 * 0.9995 / lambdaDX] ];

	  dSkScaled = RktSolve[dSk];
	  dSkScaled = Map[ Transpose, dSkScaled ];
	  dSkScaled = RktSolve[dSkScaled];
	  dSkScaled = dSkScaled + Map[ Transpose, dSkScaled ];

(*
	  alphaDS = Min[1, - 2 * 0.9995 / Min[ Map[minEig, dSkScaled] ]];
          If [ alphaDS < 0, alphaDS = 1 ];
*)

          lambdaDS = Min[ Map[minEig, dSkScaled] ];
          alphaDS = If [ lambdaDS >= 0, 1, Min[1, - 2 * 0.9995 / lambdaDS]];

          alphaTau = If [ dtauk >= 0, 1 , Min[1, - 0.9995 * tauk / dtauk] ];
          alphaRho = If [ drhok >= 0, 1 , Min[1, - 0.9995 * rhok / drhok] ];

          alpha = Min[ alphaDX, alphaDS, alphaTau, alphaRho ];

     	  (* Line search *)
     	  k = 0;    
     	  kMax = 256;
        
     	  (* start of the line search *)
	  While[ (k++ < kMax),

          	 (* calculate X+, Y+, S+ with current alpha *)
        	 Xkp = Xk + alpha * dXk; 
        	 Ykp = Yk + alpha * dYk;
        	 Skp = Sk + alpha * dSk; 
        	 taukp   = tauk   + alpha * dtauk; 
        	 thetakp = thetak + alpha * dthetak; 
        	 rhokp   = rhok   + alpha * drhok;

        	 If[ rationalizeIterates,

		     (* Rationalize current solution *)
 
		     Xkp = RationalApproximate[Xkp, rationalizeTol];
          	     Ykp = RationalApproximate[Ykp, rationalizeTol];
          	     Skp = RationalApproximate[Skp, rationalizeTol];
          	     taukp   = RationalApproximate[taukp, rationalizeTol];
          	     thetakp = RationalApproximate[thetakp, rationalizeTol];
          	     rhokp   = RationalApproximate[rhokp, rationalizeTol];

        	 ];

        	 (* Symmetrize Xk and Sk *)
        	 Xkp = ( Xkp + MatrixVectorTranspose[Xkp] ) / 2;
        	 Skp = ( Skp + MatrixVectorTranspose[Skp] ) / 2;
    
		 NCDebug[ 2, 
	         	  Xkp, Ykp, Skp, taukp, thetakp, rhokp ];

     		 (* remove the structures of Xkp and Skp *)
        	 plnXkp = MatrixVectorBlockMatrix[N[Xkp]];
        	 plnSkp = MatrixVectorBlockMatrix[N[Skp]];

        	 (* Check if Xkp and Skp are positive definite *)
        	 Quiet [
		     Check [ 
	    	         MatrixVectorCholeskyDecomposition[plnXkp];
	    		 MatrixVectorCholeskyDecomposition[plnSkp];
	    		, 
            		 alpha = 9 * alpha / 10;
	    		 Continue[];
	              (*,
		         CholeskyDecomposition::posdef *)
                     ];
          	    ,
	  	     CholeskyDecomposition::posdef
        	 ];

        	 (* Check if taukp and rhokp are positive definite *)
		 If[ taukp <= 0 || rhokp <= 0,
          	     alpha = 9 * alpha / 10;
	  	     Continue[];
		 ];

		 (* Update Rk *)
        	 Quiet[

		     (* R^T R = S *)
		     Rkp = Check[Map[CholeskyDecomposition, plnSkp], $Failed];
          	     If [ Rkp == $Failed, 
	     	     	  alpha = 9 * alpha / 10;
	     		  Continue[];
          	     ];
        	 ];

		 (* Update Lk *)
        	 Quiet[

		     (* L^T L = X *)
          	     Lkp = Check[Map[CholeskyDecomposition, plnXkp], $Failed];
          	     If [ Lkp == $Failed, 
		          alpha = 9 * alpha / 10;
	     		  Continue[];
          	     ];
        	 ];

		 (* Calculate gap *)
        	 mup = ( Total[MapThread[Total[Flatten[#1*#2]]&, {Xkp, Skp}]] 
              	     + taukp*rhokp ) / NN;

        	 NCDebug[ 2, 
	         	  mup ];

        	 RkpXkpRkpT = MapThread[Dot, {Rkp, plnXkp, Map[Transpose, Rkp]}];
        	 lambdakp = Flatten[Append[MatrixVectorEigenvalues[RkpXkpRkpT], 
                 	                    taukp*rhokp]];
 		 dFp = Sqrt[Total[(lambdakp - mup)^2]];
		 doop = Max[Abs[lambdakp - mup]];
		 dmoop = Max[mup-lambdakp];

        	 NCDebug[ 2, 
	         	  N[dFp], N[doop], N[dmoop] ];

                 (* 
 		   || X S - mu I ||^2 = || X S ||^2 - 2 mu Tr[X S] + mu^2 NN 

		   Because mu = Tr[X S] / NN

	   	   || X S - mu I ||^2 = || X S ||^2 - 2 mu^2 NN + mu^2 NN 

           	   and 

	   	   || X S - mu I || / mu = Sqrt[|| X S ||^2 / mu^2 - NN]

        	 *)   
        	 N2p2 = ( MatrixVectorFrobeniusNorm[RkpXkpRkpT]^2 
                      + (taukp*rhokp)^2 ) / mup^2 - NN;
        	 N2p = Sqrt[N2p2];

        	 Noop = Min[Min[Map[Eigenvalues, RkpXkpRkpT]]/mup, 
                        taukp*rhokp/mup];

        	 NCDebug[ 2,
                 	  N[N2p], N[N2p2], N[Noop], N[Noop/gamma] ];

                 (* check the line search stopping conditions *)
        	 condition = Switch[ method, 

	  	     ShortStep,
	   	     (dFp / mup <= gamma)

	            ,

	  	     LongStep,
	  	     (* (Noop / gamma >= 1) *)
	  	     (dmoop / mup <= gamma )
	  
		    ,

	  	     PredictorCorrector,
	  	     True

		 ];

        	 NCDebug[ 2,
                 	  condition ];

        	 If [ condition,
          	 
		     (* all fine then continue to 
		        next outer loop updating direction *) 

          	     (* Invert Sk *)
          	     Skpi = If[ rationalizeIterates,
                     	    	MatrixVectorInverse[Skp],
                     		MatrixVectorCholeskyInverse[Skp] 
		     ];

          	     If[ rationalizeIterates,

            	         (* Rationalize current solution *)
            		 Skpi = RationalApproximate[Skpi, rationalizeTol];

          	     ];
          	     Skpi = (Skpi + MatrixVectorTranspose[Skpi])/2;

          	     plnSkpi = MatrixVectorBlockMatrix[N[Skpi]];
          	     Check[ MatrixVectorCholeskyDecomposition[plnSkpi], 
	       	            Print["Inverse[Sk] is not positive definite!"] ];

	   	     (*
			Quiet[
			Skpi = Check[MatrixVectorInverse[Skp], $Failed, Inverse::luc];
			If [Skpi == $Failed, 
			alpha *=  99 / 100;
	        	Continue[];
              		];
           		];
	  	     *)

          	     Break[];
        	    ,

		     (* if not reduce alpha by a factor *)
          	     alpha = 9 * alpha / 10;

                 ];

        	 NCDebug[ 2, 
	         	  alpha ];

          ];

     	  (* line search failed *)
     	  If[ (k >= kmax),
       	      Print["Warning:: Line search failed"];
     	  ];

      ];

      If[ profiling, Print["> Line Search = ", timeLineSearch[[1]]] ];

      timeUpdates = Timing[

          NCDebug[ 1, "* Computing updates."];

	  If [ mup < muk,

            (* Update X+, Y+, S+ with current alpha *)
       	    Xk = Xkp;
     	    Yk = Ykp;
     	    Sk = Skp;
     	    tauk   = taukp;
     	    thetak = thetakp;
     	    rhok   = rhokp;
     	    Ski = Skpi;

     	    NCDebug[ 2, 
	  	   Xk, Yk, Sk, thetak, tauk ];

	    (* Other updates *)
     	    plnXk = plnXkp;
     	    plnSk = plnSkp;
     	    Rk = Rkp;
     	    Lk = Lkp;

     	    muk = mup;
     	    N2 = dFp / mup;
     	    Noo = dmoop / mup;

     	    NCDebug[ 2, 
	  	   muk ];

	    NCDebug[ 2, 
	      	   Map[MatrixVectorFrobeniusNorm,Xk],
              	   MatrixVectorFrobeniusNorm[Xk], 
              	   MatrixVectorFrobeniusNorm[Sk],
	      	   MatrixVectorFrobeniusNorm[Yk] ];

            counter++;

     	    (* calculate objective *)
     	    obj = inner[BB, Yk / tauk];

     	    (* calculate feasibility margins *)
     	    NFeasPrimal = MatrixVectorFrobeniusNorm[
       	     	      (FPrimalEval @@ Xk) - tauk * BB + thetak * BBbar 
            ];
     	    NFeasDual = MatrixVectorFrobeniusNorm[
       	     	    - (FDualEval @@ Yk) + tauk * CC - thetak * CCbar - Sk  
            ];
     	    NFeas = Abs[thetak/tauk];

     	    NCDebug[ 2, 
	    	   obj ];

	 ,

            Print["WARNING: Unproductive iteration!"];
            Print["Interrupting algorithm."];
	    Break[];

         ];

      ];

      If[ profiling, Print["> Updates = ", timeUpdates[[1]]] ];

      If[ debugLevel > 0, 
          normCentralPath = {
       		  MatrixVectorFrobeniusNorm[
			(FPrimalEval @@ Xk) - tauk * BB + thetak * BBbar 
          	  ],
         	  MatrixVectorFrobeniusNorm[
			- (FDualEval @@ Yk) + tauk * CC - thetak * CCbar - Sk  
         	  ],
         	  MatrixVectorFrobeniusInner[BB,Yk] 
    		        - MatrixVectorFrobeniusInner[CC,Xk] + thetak * zbar - rhok,
         	  MatrixVectorFrobeniusInner[BBbar,Yk] 
         	        - MatrixVectorFrobeniusInner[CCbar,Xk] + tauk * zbar - NN
          };
      ];

      NCDebug[ 2, 
	       normCentralPath ];

(*
      PrintNumber[x_, n_: 3, m_: 2] := 
        NumberForm[ x, {n+2,n},
                    ExponentFunction -> (#&) ];
*)

      NumberFormatFunction[m_, s_, e_] :=
        Row[ {NumberForm[ ToExpression[m], 
                          {4,3},
                          NumberPadding -> {" ", "0"}],
              "e", 
              NumberForm[ If[ ToExpression[e] === Null, 0, ToExpression[e]], 
                          2,
                          NumberPadding -> {"0", ""}, 
                          NumberSigns -> {"-", "+"}, 
                          SignPadding -> True]} ];

      PrintNumber[x_, n_: 3, m_: 2] := 
        ScientificForm[ x, NumberFormat -> NumberFormatFunction ];

(*
      PrintNumber[x_, n_: 4, m_: 2] := Module[
        {exp, mantissa},
        exp = Floor[Log[10, Abs[x]]];
        If[ exp === Indeterminate || exp === -Infinity,
            exp = 0;
            mantissa = 0;
           ,
            mantissa = x/(10^exp);
        ];
        Return[SequenceForm[PaddedForm[mantissa, {n+1,n}], " E", 
               PaddedForm[exp, m]]];
      ];
*)

      If [ printIterations, 
        (* show progress *)
        Print[PaddedForm[counter,2],
               " ", PrintNumber[-N[obj]], 
               " ", PrintNumber[N[muk]], 
               " ", PrintNumber[N[NFeas]], 
               " ", PrintNumber[N[alpha]], 
               " ", PrintNumber[N[N2]], 
               " ", PrintNumber[N[Noo]], 
               " ", PrintNumber[N[NFeasPrimal]], 
               " ", PrintNumber[N[NFeasDual]], 
               "", 
               If[ leastSquares === CG, PaddedForm[cgK,4], "    " ],
               "", 
               If[ leastSquares === CG, PrintNumber[N[cgRes]], "      " ]
        ];
      ];

      (* report performance *)
      If[ leastSquares === CG, 
        iters = Join[iters, {{counter, -obj, muk, Abs[thetak], cgK, cgRes}}],
	iters = Join[iters, {{counter, -obj, muk, Abs[thetak]}}]
      ];

    ];

    If [ printIterations, 
      Print[" -----------------------------------------------------",
            "--------------------------------------",
            If[ leastSquares === CG, "----------------", "" ]
      ];
    ];

    (* Extract solution *)
    Xk = Xk/tauk;
    Yk = Yk/tauk;
    Sk = Sk/tauk;

    If[ rationalizeIterates, 
 
      Xk = RationalApproximate[Xk, rationalizeTol];
      Yk = RationalApproximate[Yk, rationalizeTol];
      Sk = RationalApproximate[Sk, rationalizeTol];

      (*
        tauk   = RationalApproximate[tauk, rationalizeTol];
        thetak = RationalApproximate[thetak, rationalizeTol];
        rhok   = RationalApproximate[rhok, rationalizeTol];
      *)
    ];

    NCDebug[ 2, 
    	     tauk, thetak, rhok, Abs[thetak/tauk] ];

    If [ success, 

      (* Estimate feasibility *)
     
      dualFeasMargin = Max[Map[Eigenvalues, (FDualEval @@ Yk) - CC]];

      If [ dualFeasMargin > 0, 

         If [ dualFeasMargin < feasibilityTol, 
			  
            Print[ "* Primal solution is not strictly feasible but is within tolerance"];
            Print[ "(0 <= max eig(A* Y - C) = ", 
                   dualFeasMargin, " < ", feasibilityTol, " )" ];

            dualFeasible = True;

           ,

            Print[ "* Primal solution is not strictly feasible"];
	    Print[ "(max eig(A* Y - C) = ", 
                   dualFeasMargin, " > 0)" ];

            dualFeasible = False;

         ];

        ,

         If[ printSummary,
             Print[ "* Primal solution is feasible "];
             Print[ "(max eig(A* Y - C) = ", 
                    dualFeasMargin, " <= 0 )" ];
         ];

         dualFeasible = True;

      ];
     
      primalFeasRadius = MatrixVectorFrobeniusNorm[(FPrimalEval @@ Xk) - BB];

      If [ primalFeasRadius > feasibilityTol, 

         Print[ "* Dual solution is not within tolerance"];
	 Print[ "(|| A X - B || = ", 
                primalFeasRadius, " >= ", feasibilityTol, ")" ];

         primalFeasible = False;

        ,

         If[ printSummary,
           Print[ "* Dual solution is within tolerance"];
           Print[ "(|| A X - B || = ", 
                  primalFeasRadius, " < ", feasibilityTol, ")" ];
         ];

         primalFeasible = True;

      ];

      dualFeasRadius = If[ dualFeasMargin == 1 - feasibilityTol,
                         Infinity, 
                         Abs[(1 + dualFeasMargin - feasibilityTol) / (1 - dualFeasMargin + feasibilityTol)] ];

      Print[ "* Feasibility radius = ", dualFeasRadius];
      Print[ "  (should be less than 1 when feasible)" ];

      ,

        Print["* Algorithm interrupted before reaching requested precision"];
        Print["* Problem may be unfeasible"];
 
    ];

    (* numerical result *)
    Return[{Yk, Xk, Sk, 
            {
             PrimalDual`FeasibilityRadius -> dualFeasRadius, 
             PrimalDual`PrimalFeasible -> dualFeasible, 
             PrimalDual`PrimalFeasibilityMargin -> dualFeasMargin, 
             PrimalDual`DualFeasible -> primalFeasible,
             PrimalDual`DualFeasibilityRadius -> primalFeasRadius
            }
           }];

  ];

End[]

EndPackage[]