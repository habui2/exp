MODULE FIRE
 
! Compute combustion 
 
USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: SECOND
 
IMPLICIT NONE
PRIVATE
CHARACTER(255), PARAMETER :: fireid='$Id$'
CHARACTER(255), PARAMETER :: firerev='$Revision$'
CHARACTER(255), PARAMETER :: firedate='$Date$'

TYPE(REACTION_TYPE), POINTER :: RN=>NULL()
REAL(EB) :: Q_UPPER

PUBLIC COMBUSTION, GET_REV_fire
 
CONTAINS
 

SUBROUTINE COMBUSTION(NM)

INTEGER, INTENT(IN) :: NM
REAL(EB) :: TNOW

IF (EVACUATION_ONLY(NM)) RETURN

TNOW=SECOND()

IF (INIT_HRRPUV) RETURN

CALL POINT_TO_MESH(NM)

! Upper bounds on local HRR per unit volume

Q_UPPER = HRRPUA_SHEET/CELL_SIZE + HRRPUV_AVERAGE

! Call combustion ODE solver
IF (NEW_COMBUSTION) THEN
   CALL COMBUSTION_GENERAL
ELSE
   CALL COMBUSTION_SOLVER
ENDIF

TUSED(10,NM)=TUSED(10,NM)+SECOND()-TNOW

END SUBROUTINE COMBUSTION



SUBROUTINE COMBUSTION_SOLVER

USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT,GET_AVERAGE_SPECIFIC_HEAT
REAL(EB) :: Y_FU_0,Y_P_0,Y_LIMITER,Y_O2_0,DYF,DELTA, & 
            Q_NEW,O2_F_RATIO,Q_BOUND_1,Q_BOUND_2,ZZ_GET(0:N_TRACKED_SPECIES), &
            DYAIR,TAU_D,TAU_U,TAU_G,EPSK,KSGS,CPBAR_F_0,CPBAR_F_N,CPBAR_G_0,CPBAR_G_N,&
            DUDX,DUDY,DUDZ,DVDX,DVDY,DVDZ,DWDX,DWDY,DWDZ,SS2,S12,S13,S23
REAL(EB), PARAMETER :: Y_FU_MIN=1.E-10_EB,Y_O2_MIN=1.E-10_EB
INTEGER :: I,J,K,IC,ITMP,N,II,JJ,KK,IW,IIG,JJG,KKG
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL()

! Misc initializations

RN => REACTION(1)
O2_F_RATIO = RN%NU(0)     *SPECIES(O2_INDEX)%MW  *SPECIES_MIXTURE(0)%VOLUME_FRACTION(O2_INDEX)/ &
            (RN%NU(RN%FUEL_SMIX_INDEX)*SPECIES(FUEL_INDEX)%MW*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%VOLUME_FRACTION(FUEL_INDEX))

UU => US
VV => VS
WW => WS

!$OMP PARALLEL DEFAULT(NONE) & 
!$    SHARED(MIX_TIME,DT,Q,D_REACTION, &
!$           IBAR,KBAR,JBAR,CELL_INDEX,SOLID,RN,SPECIES_MIXTURE,FUEL_INDEX,O2_INDEX,ZZ,I_PRODUCTS, &
!$           Y_P_MIN_EDC,SUPPRESSION,TMP,O2_F_RATIO,N_TRACKED_SPECIES, &
!$           USE_MAX_FILTER_WIDTH,DX,DY,DZ,TWO_D,LES,SC,RHO,MU,RDX,RDY,RDZ,UU,VV,WW,PI,GRAV, &
!$           TAU_CHEM,TAU_FLAME,D_Z,FIXED_MIX_TIME,BETA_EDC,Q_UPPER,RSUM, &
!$           N_EXTERNAL_WALL_CELLS,BOUNDARY_TYPE,IJKW)


!$OMP WORKSHARE
MIX_TIME   = DT
Q          = 0._EB
D_REACTION = 0._EB
!$OMP END WORKSHARE

!$OMP DO COLLAPSE(3) SCHEDULE(DYNAMIC) &
!$    PRIVATE(K,J,I,IC,Y_FU_0,Y_O2_0,Y_P_0,DYF,ZZ_GET,CPBAR_F_0,CPBAR_F_N,CPBAR_G_0,CPBAR_G_N,DYAIR,DELTA, &
!$            TAU_D,DUDX,DUDY,DUDZ,DVDX,DVDY,DVDZ,DWDX,DWDY,DWDZ,S12,S13,S23,SS2,EPSK,KSGS,TAU_U,TAU_G,ITMP, &
!$            Y_LIMITER,Q_BOUND_1,Q_BOUND_2,Q_NEW,N)
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR

         IC = CELL_INDEX(I,J,K)
         IF (SOLID(IC)) CYCLE

         Y_FU_0  = ZZ(I,J,K,RN%FUEL_SMIX_INDEX)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MASS_FRACTION(FUEL_INDEX)
         IF (Y_FU_0<=Y_FU_MIN) CYCLE
         Y_O2_0  = (1._EB-SUM(ZZ(I,J,K,:)))*SPECIES_MIXTURE(0)%MASS_FRACTION(O2_INDEX)
         IF (Y_O2_0<=Y_O2_MIN) CYCLE
         Y_P_0 = ZZ(I,J,K,I_PRODUCTS)*RN%NU(RN%FUEL_SMIX_INDEX)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/&
                                     (RN%NU(RN%FUEL_SMIX_INDEX)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW+&
                                      RN%NU(0)*SPECIES_MIXTURE(0)%MW)
         Y_P_0 = MAX(Y_P_MIN_EDC,Y_P_0)

         IF_SUPPRESSION: IF (SUPPRESSION) THEN

            ! Evaluate empirical extinction criteria

            IF (TMP(I,J,K) < RN%AUTO_IGNITION_TEMPERATURE) CYCLE
            DYF = MIN(Y_FU_0,Y_O2_0/O2_F_RATIO) 
            ZZ_GET = 0._EB
            ZZ_GET(RN%FUEL_SMIX_INDEX) = 1._EB
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_0,TMP(I,J,K)) 
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_N,RN%CRIT_FLAME_TMP)
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
            ZZ_GET(RN%FUEL_SMIX_INDEX) = 0._EB
            ZZ_GET = ZZ_GET / (1._EB - Y_FU_0)
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_0,TMP(I,J,K)) 
            CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_N,RN%CRIT_FLAME_TMP) 
            DYAIR = DYF * (1._EB - Y_FU_0) / Y_O2_0 * O2_F_RATIO
            IF ( (DYF*CPBAR_F_0 + DYAIR*CPBAR_G_0)*TMP(I,J,K) + DYF*RN%HEAT_OF_COMBUSTION < &
                 (DYF*CPBAR_F_N + DYAIR*CPBAR_G_N)*RN%CRIT_FLAME_TMP) CYCLE

         ENDIF IF_SUPPRESSION

         IF (USE_MAX_FILTER_WIDTH) THEN
            DELTA=MAX(DX(I),DY(J),DZ(K))
         ELSE
            IF (.NOT.TWO_D) THEN
               DELTA = (DX(I)*DY(J)*DZ(K))**ONTH
            ELSE
               DELTA = SQRT(DX(I)*DZ(K))
            ENDIF
         ENDIF

         LES_IF: IF (LES) THEN

            TAU_D = SC*RHO(I,J,K)*DELTA**2/MU(I,J,K)   ! diffusive time scale         
            
            ! compute local filtered strain

            DUDX = RDX(I)*(UU(I,J,K)-UU(I-1,J,K))
            DVDY = RDY(J)*(VV(I,J,K)-VV(I,J-1,K))
            DWDZ = RDZ(K)*(WW(I,J,K)-WW(I,J,K-1))
            DUDY = 0.25_EB*RDY(J)*(UU(I,J+1,K)-UU(I,J-1,K)+UU(I-1,J+1,K)-UU(I-1,J-1,K))
            DUDZ = 0.25_EB*RDZ(K)*(UU(I,J,K+1)-UU(I,J,K-1)+UU(I-1,J,K+1)-UU(I-1,J,K-1)) 
            DVDX = 0.25_EB*RDX(I)*(VV(I+1,J,K)-VV(I-1,J,K)+VV(I+1,J-1,K)-VV(I-1,J-1,K))
            DVDZ = 0.25_EB*RDZ(K)*(VV(I,J,K+1)-VV(I,J,K-1)+VV(I,J-1,K+1)-VV(I,J-1,K-1))
            DWDX = 0.25_EB*RDX(I)*(WW(I+1,J,K)-WW(I-1,J,K)+WW(I+1,J,K-1)-WW(I-1,J,K-1))
            DWDY = 0.25_EB*RDY(J)*(WW(I,J+1,K)-WW(I,J-1,K)+WW(I,J+1,K-1)-WW(I,J-1,K-1))
            S12 = 0.5_EB*(DUDY+DVDX)
            S13 = 0.5_EB*(DUDZ+DWDX)
            S23 = 0.5_EB*(DVDZ+DWDY)
            SS2 = 2._EB*(DUDX**2 + DVDY**2 + DWDZ**2 + 2._EB*(S12**2 + S13**2 + S23**2))
            
            ! ke dissipation rate, assumes production=dissipation

            EPSK = MU(I,J,K)*(SS2-TWTH*(DUDX+DVDY+DWDZ)**2)/RHO(I,J,K)

            KSGS = 2.25_EB*(EPSK*DELTA/PI)**TWTH  ! estimate of subgrid ke, from Kolmogorov spectrum

            TAU_U = DELTA/SQRT(2._EB*KSGS+1.E-10_EB)   ! advective time scale
            TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB)) ! acceleration time scale

            MIX_TIME(I,J,K)=MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME)) ! Eq. 7, McDermott, McGrattan, Floyd
         ELSE LES_IF
            ITMP = MIN(4999,NINT(TMP(I,J,K)))
            TAU_D = D_Z(ITMP,RN%FUEL_SMIX_INDEX)
            TAU_D = DELTA**2/TAU_D
            MIX_TIME(I,J,K)= TAU_D
         ENDIF LES_IF
         
         IF (FIXED_MIX_TIME>0._EB) MIX_TIME(I,J,K)=FIXED_MIX_TIME
         
         Y_LIMITER = MIN(Y_FU_0, Y_O2_0/O2_F_RATIO, BETA_EDC*Y_P_0)
         DYF = Y_LIMITER*(1._EB-EXP(-DT/MIX_TIME(I,J,K)))
         Q_BOUND_1 = DYF*RHO(I,J,K)*RN%HEAT_OF_COMBUSTION/DT
         Q_BOUND_2 = Q_UPPER
         Q_NEW = MIN(Q_BOUND_1,Q_BOUND_2)
         DYF = Q_NEW*DT/(RHO(I,J,K)*RN%HEAT_OF_COMBUSTION)
         
         Q(I,J,K)  = Q_NEW

         DO N=1,N_TRACKED_SPECIES
            ZZ(I,J,K,N) = ZZ(I,J,K,N) + DYF*RN%NU(N)*SPECIES_MIXTURE(N)%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW
         ENDDO

         ! Compute new mixture molecular weight

         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K)) 

      ENDDO
   ENDDO
ENDDO
!$OMP END DO

! Set Q in the ghost cell, just for better visualization.

!$OMP DO SCHEDULE(DYNAMIC) &
!$    PRIVATE(IW,II,JJ,KK,IIG,JJG,KKG)
DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (BOUNDARY_TYPE(IW)/=INTERPOLATED_BOUNDARY .AND. BOUNDARY_TYPE(IW)/=OPEN_BOUNDARY) CYCLE
   II  = IJKW(1,IW)
   JJ  = IJKW(2,IW)
   KK  = IJKW(3,IW)
   IIG = IJKW(6,IW)
   JJG = IJKW(7,IW)
   KKG = IJKW(8,IW)
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO
!$OMP END DO NOWAIT

!$OMP END PARALLEL

END SUBROUTINE COMBUSTION_SOLVER


SUBROUTINE COMBUSTION_GENERAL

! Generic combustion routine for multi step reactions with kinetics either mixing controlled, finite rate, 
! or a temperature threshhold mixed approach

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL
INTEGER :: I,J,K,NS,NR,II,JJ,KK,IIG,JJG,KKG,IW
REAL(EB):: ZZ_GET(0:N_TRACKED_SPECIES),ZZ_MIN=1.E-10_EB
LOGICAL :: DO_REACTION,REACTANTS_PRESENT,Q_EXISTS
TYPE (REACTION_TYPE),POINTER :: RN

Q = 0._EB
Q_EXISTS = .FALSE.
DO K=1,KBAR
   DO J=1,JBAR
      ILOOP: DO I=1,IBAR
         !Check to see if a reaction is possible
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ILOOP
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         ZZ_GET(0) = 1._EB - MIN(1._EB,SUM(ZZ_GET(1:N_TRACKED_SPECIES)))
         DO_REACTION = .FALSE.
         DO NR=1,N_REACTIONS
            RN=>REACTION(NR)
            REACTANTS_PRESENT = .TRUE.
            DO NS=0,N_TRACKED_SPECIES
               IF (RN%NU(NS)<0._EB .AND. ZZ_GET(NS) < ZZ_MIN) THEN
                  REACTANTS_PRESENT = .FALSE.
                  EXIT
               ENDIF
            END DO
            IF (.NOT. DO_REACTION) DO_REACTION = REACTANTS_PRESENT     
         END DO
         IF (.NOT. DO_REACTION) CYCLE ILOOP 
         
         ! Easily allow for user selected ODE solver
         SELECT CASE (COMBUSTION_ODE)
            CASE(SINGLE_EXACT)
               CALL ODE_EXACT(I,J,K,ZZ_GET,Q(I,J,K))
            CASE(EXPLICIT_EULER)
               CALL ODE_EXPLICIT_EULER(I,J,K,ZZ_GET,Q(I,J,K))
         END SELECT        

         !Update RSUM and ZZ         
         IF (Q(I,J,K) > 0._EB) THEN
            Q_EXISTS = .TRUE.
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K)) 
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES)
            ! Divergence term would be inserted here
         ENDIF
      ENDDO ILOOP
   ENDDO
ENDDO

IF (.NOT. Q_EXISTS) RETURN

! Set Q in the ghost cell, just for better visualization.
DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (BOUNDARY_TYPE(IW)/=INTERPOLATED_BOUNDARY .AND. BOUNDARY_TYPE(IW)/=OPEN_BOUNDARY) CYCLE
   II  = IJKW(1,IW)
   JJ  = IJKW(2,IW)
   KK  = IJKW(3,IW)
   IIG = IJKW(6,IW)
   JJG = IJKW(7,IW)
   KKG = IJKW(8,IW)
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO

END SUBROUTINE COMBUSTION_GENERAL

SUBROUTINE ODE_EXACT(I,J,K,ZZ_GET,Q_NEW)
INTEGER,INTENT(IN):: I,J,K
REAL(EB),INTENT(OUT):: Q_NEW
REAL(EB),INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: DZF,Q_BOUND_1,Q_BOUND_2,RATE_CONSTANT,Z_LIMITER,REACTANT_MIN,DT2
LOGICAL :: MIN_FOUND
INTEGER :: NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

Q_NEW = 0._EB
RN=>REACTION(1)
CALL COMPUTE_RATE_CONSTANT(1,RN%MODE,1,0._EB,RATE_CONSTANT,ZZ_GET,I,J,K)

IF(RATE_CONSTANT < ZERO_P) RETURN

Z_LIMITER = RATE_CONSTANT*MIX_TIME(I,J,K)

DZF = -1._EB
!Check for reactant (i.e. fuel or oxidizer) limited combustion
MIN_FOUND = .FALSE.
REACTANT_MIN=1._EB
DO NS=0,N_TRACKED_SPECIES
   IF (RN%NU(NS) < -ZERO_P) &
      REACTANT_MIN = MIN(REACTANT_MIN,-ZZ_GET(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(SPECIES_MIXTURE(NS)%MW*RN%NU(NS)))
   IF (ABS(Z_LIMITER - REACTANT_MIN) <= SPACING(Z_LIMITER)) THEN
      MIN_FOUND = .TRUE.
      DZF = REACTANT_MIN*(1._EB-EXP(-DT/MIX_TIME(I,J,K)))
      EXIT
   ENDIF
ENDDO

!For product limited combsiton find time of switch from product limited to reactant limited (if it occurs)
!and do two step exact solution
IF (.NOT. MIN_FOUND) THEN
   DT2 = MIX_TIME(I,J,K)*LOG((Z_LIMITER+REACTANT_MIN)/(2._EB*Z_LIMITER))
   IF (DT2 < DT) THEN
      DZF = ZZ_GET(RN%FUEL_SMIX_INDEX) - Z_LIMITER*(EXP(DT2/MIX_TIME(I,J,K))-1._EB)
      REACTANT_MIN = REACTANT_MIN - DZF
      DZF = DZF + REACTANT_MIN*(1._EB-EXP(-(DT-DT2)/MIX_TIME(I,J,K)))
   ELSE
      DZF = ZZ_GET(RN%FUEL_SMIX_INDEX) - Z_LIMITER*(EXP(DT/MIX_TIME(I,J,K))-1._EB)
   ENDIF
ENDIF

DZF = MIN(DZF,ZZ_GET(RN%FUEL_SMIX_INDEX))

!****** TEMP OVERRIDE TO ENSURE SAME RESULTS AS PREVIOUS *******
!DZF = Z_LIMITER*(1._EB-EXP(-DT/MIX_TIME(I,J,K)))
!***************************************************************

Q_BOUND_1 = DZF*RHO(I,J,K)*RN%HEAT_OF_COMBUSTION/DT
Q_BOUND_2 = Q_UPPER
Q_NEW = MIN(Q_BOUND_1,Q_BOUND_2)
DZF = Q_NEW*DT/(RHO(I,J,K)*RN%HEAT_OF_COMBUSTION)         

ZZ_GET = ZZ_GET + DZF*RN%NU*SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW


END SUBROUTINE ODE_EXACT

SUBROUTINE ODE_EXPLICIT_EULER(I,J,K,ZZ_GET,Q_OUT)
INTEGER,INTENT(IN):: I,J,K
REAL(EB),INTENT(OUT):: Q_OUT
REAL(EB),INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: ZZ_0(0:N_TRACKED_SPECIES),ZZ_I(0:N_TRACKED_SPECIES),ZZ_N(0:N_TRACKED_SPECIES),DZZDT(0:N_TRACKED_SPECIES),&
            DT_ODE,DT_NEW,RATE_CONSTANT(1:N_REACTIONS),Q_NR(1:N_REACTIONS),DT_SUM
INTEGER :: NR,I_TS,NODETS=20,NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()


Q_OUT = 0._EB
ZZ_0 = MAX(0._EB,ZZ_GET)
ZZ_I = ZZ_0
DT_ODE = DT/REAL(NODETS,EB)
DT_NEW = DT_ODE
DT_SUM = 0._EB
I_TS = 1
ODE_LOOP: DO WHILE (DT_SUM < DT)
   DZZDT = 0._EB
   RATE_CONSTANT = 0._EB
   Q_NR = 0._EB
   REACTION_LOOP: DO NR = 1, N_REACTIONS   
      RN => REACTION(NR)      
      CALL COMPUTE_RATE_CONSTANT(NR,RN%MODE,I_TS,Q_OUT,RATE_CONSTANT(NR),ZZ_I,I,J,K)
      IF (RATE_CONSTANT(NR) < ZERO_P) CYCLE REACTION_LOOP
      Q_NR(NR) = RATE_CONSTANT(NR)*RN%HEAT_OF_COMBUSTION*RHO(I,J,K)
      DZZDT = DZZDT + RN%NU * SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW*RATE_CONSTANT(NR)
      !IF(I==12 .AND. K==10) WRITE(*,'(1X,I2,3(E14.7,1X))') I_TS,RATE_CONSTANT(NR),RN%HEAT_OF_COMBUSTION
      !IF(I==12 .AND. K==10) &
      !WRITE(*,'(1X,6(E12.5,1X))') RN%NU * SPECIES_MIXTURE%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW*RATE_CONSTANT(NR)
      !IF(I==12 .AND. K==10) WRITE(*,'(1X,6(E12.5,1X))') DZZDT
   END DO REACTION_LOOP     
   IF (ALL(DZZDT < ZERO_P)) EXIT ODE_LOOP
   ZZ_N = ZZ_I + DZZDT * DT_NEW
   IF (ANY(ZZ_N < 0._EB)) THEN
      DO NS=0,N_TRACKED_SPECIES
          IF (ZZ_N(NS) < 0._EB .AND. ABS(DZZDT(NS))>ZERO_P) DT_NEW = MIN(DT_NEW,-ZZ_I(NS)/DZZDT(NS))
      ENDDO
   ENDIF  
   !IF(I==12 .AND. K==10) WRITE(*,*) DT_ODE,DT_NEW,Q_OUT + SUM(Q_NR)*DT_NEW
   IF (Q_OUT + SUM(Q_NR)*DT_NEW > Q_UPPER * DT) THEN
      DT_NEW = MAX(0._EB,(Q_UPPER * DT - Q_OUT))/SUM(Q_NR)
      Q_OUT = Q_OUT+SUM(Q_NR)*DT_NEW
      ZZ_I = ZZ_I + DZZDT * DT_NEW
      EXIT ODE_LOOP
   ENDIF   
   Q_OUT = Q_OUT+SUM(Q_NR)*DT_NEW
   
   ZZ_I = ZZ_I + DZZDT * DT_NEW
   DT_SUM = DT_SUM + DT_NEW
   IF (DT_NEW < DT_ODE) DT_NEW = DT_ODE
   IF (DT_NEW + DT_SUM > DT) DT_NEW = DT - DT_SUM
   I_TS = I_TS + 1
ENDDO ODE_LOOP

ZZ_GET = ZZ_GET + ZZ_I - ZZ_0
Q_OUT = Q_OUT / DT

RETURN

END SUBROUTINE ODE_EXPLICIT_EULER


RECURSIVE SUBROUTINE COMPUTE_RATE_CONSTANT(NR,MODE,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)
USE PHYSICAL_FUNCTIONS, ONLY : GET_MASS_FRACTION_ALL
REAL(EB), INTENT(IN) :: ZZ_GET(0:N_TRACKED_SPECIES),Q_IN
INTEGER, INTENT(IN) :: NR,I_TS,MODE,I,J,K
REAL(EB), INTENT(INOUT) :: RATE_CONSTANT
REAL(EB) :: YY_PRIMITIVE(1:N_SPECIES),Y_F_MIN=1.E-15_EB,ZZ_MIN=1.E-10_EB,YY_F_LIM,ZZ_REACTANT,ZZ_PRODUCT, &
            TAU_D,TAU_G,TAU_U,DELTA
INTEGER :: NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

RN => REACTION(NR)

SELECT CASE (MODE)
   CASE(MIXED)
      IF (Q_IN > 0._EB .AND. RN%THRESHOLD_TEMP >= TMP(I,J,K)) THEN
         CALL COMPUTE_RATE_CONSTANT(NR,MIXING_CONTROLLED,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)
      ELSE
         CALL COMPUTE_RATE_CONSTANT(NR,FINITE_RATE,I_TS,Q_IN,RATE_CONSTANT,ZZ_GET,I,J,K)      
      ENDIF
   CASE(MIXING_CONTROLLED)
      
         IF_SUPPRESSION: IF (SUPPRESSION) THEN
            ! Evaluate empirical extinction criteria
            IF (I_TS==1) THEN
                IF(EXTINCTION(I,J,K,ZZ_GET)) THEN
                   RATE_CONSTANT = 0._EB
                   RETURN
                ENDIF
            ELSE
               IF (RATE_CONSTANT <= ZERO_P) RETURN
            ENDIF
         ENDIF IF_SUPPRESSION

         IF (USE_MAX_FILTER_WIDTH) THEN
            DELTA=MAX(DX(I),DY(J),DZ(K))
         ELSE
            IF (.NOT.TWO_D) THEN
               DELTA = (DX(I)*DY(J)*DZ(K))**ONTH
            ELSE
               DELTA = SQRT(DX(I)*DZ(K))
            ENDIF
         ENDIF

         LES_IF: IF (LES) THEN

            TAU_D = SC*RHO(I,J,K)*DELTA**2/MU(I,J,K)   ! diffusive time scale         
            TAU_U = DELTA/SQRT(2._EB*KSGS(I,J,K)+1.E-10_EB)   ! advective time scale
            TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB)) ! acceleration time scale
            MIX_TIME(I,J,K)=MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME)) ! Eq. 7, McDermott, McGrattan, Floyd

         ELSE LES_IF

            TAU_D = D_Z(MIN(4999,NINT(TMP(I,J,K))),RN%FUEL_SMIX_INDEX)
            TAU_D = DELTA**2/TAU_D
            MIX_TIME(I,J,K)= TAU_D

         ENDIF LES_IF
         YY_F_LIM=1.E15_EB
         IF (N_REACTIONS > 1) THEN
            DO NS=0,N_TRACKED_SPECIES
               IF(RN%NU(NS) < -ZERO_P) THEN
                  IF (ZZ_GET(NS) < ZZ_MIN) THEN
                     RATE_CONSTANT = 0._EB
                     RETURN
                  ENDIF
                  YY_F_LIM = MIN(YY_F_LIM,&
                                 ZZ_GET(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(ABS(RN%NU(NS))*SPECIES_MIXTURE(NS)%MW))
               ENDIF
            ENDDO
         ELSE
            ZZ_REACTANT = 0._EB
            ZZ_PRODUCT = 0._EB
            DO NS=0,N_TRACKED_SPECIES
               IF(RN%NU(NS) < -ZERO_P) THEN
                  IF (ZZ_GET(NS) < ZZ_MIN) THEN
                     RATE_CONSTANT = 0._EB
                     RETURN
                  ENDIF               
                  ZZ_REACTANT = ZZ_REACTANT - RN%NU(NS)*SPECIES_MIXTURE(NS)%MW
                  YY_F_LIM = MIN(YY_F_LIM,&
                                 ZZ_GET(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(ABS(RN%NU(NS))*SPECIES_MIXTURE(NS)%MW))
               ELSEIF(RN%NU(NS)>ZERO_P ) THEN
                  ZZ_PRODUCT = ZZ_PRODUCT + ZZ_GET(NS)
               ENDIF
            ENDDO
            ZZ_PRODUCT = BETA_EDC*MAX(ZZ_PRODUCT*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/ZZ_REACTANT,Y_P_MIN_EDC)
            YY_F_LIM = MIN(YY_F_LIM,ZZ_PRODUCT)
         ENDIF
         YY_F_LIM = MAX(YY_F_LIM,Y_F_MIN)
         IF (FIXED_MIX_TIME>0._EB) MIX_TIME(I,J,K)=FIXED_MIX_TIME      
         RATE_CONSTANT =  YY_F_LIM/MIX_TIME(I,J,K)      
      
   CASE(FINITE_RATE)
      RATE_CONSTANT = 0._EB
      CALL GET_MASS_FRACTION_ALL(ZZ_GET,YY_PRIMITIVE)
      RATE_CONSTANT = RN%A*RHO(I,J,K)**RN%RHO_EXPONENT*EXP(-RN%E/(R0*TMP(I,J,K)))*TMP(I,J,K)**RN%N_T
      DO NS=1,N_SPECIES
         IF(RN%N_S(NS)>= -998._EB) THEN
            IF (YY_PRIMITIVE(NS) < ZZ_MIN) THEN
               RATE_CONSTANT = 0._EB
               RETURN
            ENDIF
            RATE_CONSTANT = YY_PRIMITIVE(NS)**RN%N_S(NS)*RATE_CONSTANT
         ENDIF
      ENDDO

END SELECT

RETURN

CONTAINS

LOGICAL FUNCTION EXTINCTION(I,J,K,ZZ_IN)
!This routine determines if local extinction occurs for a mixing controlled reaction.
!This is determined as follows:
!1) Determine how much fuel can burn (DZ_FUEL) by finding the limiting reactant and expressing it in terms of fuel mass
!2) Remove that amount of fuel form the local mixture, everything else is "air"  
!   (i.e. if we are fuel rich, excess fuel acts as a diluent)
!3) Search to find the minimum reactant other than fuel.  
!   Using the reaction stoichiometry, determine how much "air" (DZ_AIR) is needed to burn the fuel.
!4) GET_AVERAGE_SPECIFIC_HEAT for the fuel and the "air" at the current temp and the critical flame temp
!5) Check to see if the heat released from burning DZ_FUEL can raise the current temperature of DZ_FUEL and DZ_AIR
!   above the critical flame temp.
USE PHYSICAL_FUNCTIONS,ONLY:GET_AVERAGE_SPECIFIC_HEAT
REAL(EB),INTENT(IN)::ZZ_IN(0:N_TRACKED_SPECIES)
REAL(EB):: DZ_AIR,DZ_FUEL,CPBAR_F_0,CPBAR_F_N,CPBAR_G_0,CPBAR_G_N,ZZ_GET(0:N_TRACKED_SPECIES)
INTEGER, INTENT(IN) :: I,J,K
INTEGER :: NS

EXTINCTION = .FALSE.
IF (TMP(I,J,K) < RN%AUTO_IGNITION_TEMPERATURE) THEN
   EXTINCTION = .TRUE.
ELSE
   DZ_FUEL = 1._EB
   DZ_AIR = 0._EB
   !Search reactants to find limiting reactant and express it as fuel mass.  This is the amount of fuel
   !that can burn
   DO NS = 0,N_TRACKED_SPECIES
      IF (RN%NU(NS)<-ZERO_P) &
         DZ_FUEL = MIN(DZ_FUEL,-ZZ_IN(NS)*SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/(RN%NU(NS)*SPECIES_MIXTURE(NS)%MW))
   ENDDO
   !Get the specific heat for the fuel at the current and critical flame temperatures
   ZZ_GET = 0._EB
   ZZ_GET(RN%FUEL_SMIX_INDEX) = 1._EB
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_0,TMP(I,J,K)) 
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_F_N,RN%CRIT_FLAME_TMP)
   ZZ_GET = ZZ_IN
   !Remove the burnable fuel from the local mixture and renormalize.  The remainder is "air"
   ZZ_GET(RN%FUEL_SMIX_INDEX) = ZZ_GET(RN%FUEL_SMIX_INDEX) - DZ_FUEL
   ZZ_GET = ZZ_GET/SUM(ZZ_GET)     
   !Get the specific heat for the "air"
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_0,TMP(I,J,K)) 
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR_G_N,RN%CRIT_FLAME_TMP) 
   !Loop over non-fuel reactants and find the mininum.  Determine how much "air" is needed to provide the limting reactant
   DO NS = 0,N_TRACKED_SPECIES   
            IF (RN%NU(NS)<-ZERO_P .AND. NS/=RN%FUEL_SMIX_INDEX) &
              DZ_AIR = MAX(DZ_AIR, -DZ_FUEL*RN%NU(NS)*SPECIES_MIXTURE(NS)%MW/SPECIES_MIXTURE(RN%FUEL_SMIX_INDEX)%MW/ZZ_GET(NS))
   ENDDO
   !See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp
   IF ( (DZ_FUEL*CPBAR_F_0 + DZ_AIR*CPBAR_G_0)*TMP(I,J,K) + DZ_FUEL*RN%HEAT_OF_COMBUSTION < &
         (DZ_FUEL*CPBAR_F_N + DZ_AIR*CPBAR_G_N)*RN%CRIT_FLAME_TMP) EXTINCTION = .TRUE.
ENDIF

END FUNCTION EXTINCTION


REAL(EB) FUNCTION KSGS(I,J,K)
INTEGER, INTENT(IN) :: I,J,K
REAL(EB) :: DUDX,DVDY,DWDZ,DUDY,DUDZ,DVDX,DVDZ,DWDX,DWDY,S12,S13,S23,SS2,EPSK

! compute local filtered strain

DUDX = RDX(I)*(US(I,J,K)-US(I-1,J,K))
DVDY = RDY(J)*(VS(I,J,K)-VS(I,J-1,K))
DWDZ = RDZ(K)*(WS(I,J,K)-WS(I,J,K-1))
DUDY = 0.25_EB*RDY(J)*(US(I,J+1,K)-US(I,J-1,K)+US(I-1,J+1,K)-US(I-1,J-1,K))
DUDZ = 0.25_EB*RDZ(K)*(US(I,J,K+1)-US(I,J,K-1)+US(I-1,J,K+1)-US(I-1,J,K-1)) 
DVDX = 0.25_EB*RDX(I)*(VS(I+1,J,K)-VS(I-1,J,K)+VS(I+1,J-1,K)-VS(I-1,J-1,K))
DVDZ = 0.25_EB*RDZ(K)*(VS(I,J,K+1)-VS(I,J,K-1)+VS(I,J-1,K+1)-VS(I,J-1,K-1))
DWDX = 0.25_EB*RDX(I)*(WS(I+1,J,K)-WS(I-1,J,K)+WS(I+1,J,K-1)-WS(I-1,J,K-1))
DWDY = 0.25_EB*RDY(J)*(WS(I,J+1,K)-WS(I,J-1,K)+WS(I,J+1,K-1)-WS(I,J-1,K-1))
S12 = 0.5_EB*(DUDY+DVDX)
S13 = 0.5_EB*(DUDZ+DWDX)
S23 = 0.5_EB*(DVDZ+DWDY)
SS2 = 2._EB*(DUDX**2 + DVDY**2 + DWDZ**2 + 2._EB*(S12**2 + S13**2 + S23**2))

! ke dissipation rate, assumes production=dissipation

EPSK = MU(I,J,K)*(SS2-TWTH*(DUDX+DVDY+DWDZ)**2)/RHO(I,J,K)

KSGS = 2.25_EB*(EPSK*DELTA/PI)**TWTH  ! estimate of subgrid ke, from Kolmogorov spectrum

END FUNCTION KSGS

END SUBROUTINE COMPUTE_RATE_CONSTANT


SUBROUTINE GET_REV_fire(MODULE_REV,MODULE_DATE)
INTEGER,INTENT(INOUT) :: MODULE_REV
CHARACTER(255),INTENT(INOUT) :: MODULE_DATE

WRITE(MODULE_DATE,'(A)') firerev(INDEX(firerev,':')+1:LEN_TRIM(firerev)-2)
READ (MODULE_DATE,'(I5)') MODULE_REV
WRITE(MODULE_DATE,'(A)') firedate

END SUBROUTINE GET_REV_fire
 
END MODULE FIRE

