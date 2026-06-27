---- MODULE TransferNonAtomic_TTrace_1782539810 ----
EXTENDS Sequences, TransferNonAtomic, TLCExt, Toolbox, Naturals, TLC

_expression ==
    LET TransferNonAtomic_TEExpression == INSTANCE TransferNonAtomic_TEExpression
    IN TransferNonAtomic_TEExpression!expression
----

_trace ==
    LET TransferNonAtomic_TETrace == INSTANCE TransferNonAtomic_TETrace
    IN TransferNonAtomic_TETrace!trace
----

_inv ==
    ~(
        TLCGet("level") = Len(_TETrace)
        /\
        b_step = ("idle")
        /\
        bob = (100)
        /\
        alice = (70)
        /\
        a_step = ("credited")
    )
----

_init ==
    /\ b_step = _TETrace[1].b_step
    /\ alice = _TETrace[1].alice
    /\ a_step = _TETrace[1].a_step
    /\ bob = _TETrace[1].bob
----

_next ==
    /\ \E i,j \in DOMAIN _TETrace:
        /\ \/ /\ j = i + 1
              /\ i = TLCGet("level")
        /\ b_step  = _TETrace[i].b_step
        /\ b_step' = _TETrace[j].b_step
        /\ alice  = _TETrace[i].alice
        /\ alice' = _TETrace[j].alice
        /\ a_step  = _TETrace[i].a_step
        /\ a_step' = _TETrace[j].a_step
        /\ bob  = _TETrace[i].bob
        /\ bob' = _TETrace[j].bob

\* Uncomment the ASSUME below to write the states of the error trace
\* to the given file in Json format. Note that you can pass any tuple
\* to `JsonSerialize`. For example, a sub-sequence of _TETrace.
    \* ASSUME
    \*     LET J == INSTANCE Json
    \*         IN J!JsonSerialize("TransferNonAtomic_TTrace_1782539810.json", _TETrace)

=============================================================================

 Note that you can extract this module `TransferNonAtomic_TEExpression`
  to a dedicated file to reuse `expression` (the module in the 
  dedicated `TransferNonAtomic_TEExpression.tla` file takes precedence 
  over the module `TransferNonAtomic_TEExpression` below).

---- MODULE TransferNonAtomic_TEExpression ----
EXTENDS Sequences, TransferNonAtomic, TLCExt, Toolbox, Naturals, TLC

expression == 
    [
        \* To hide variables of the `TransferNonAtomic` spec from the error trace,
        \* remove the variables below.  The trace will be written in the order
        \* of the fields of this record.
        b_step |-> b_step
        ,alice |-> alice
        ,a_step |-> a_step
        ,bob |-> bob
        
        \* Put additional constant-, state-, and action-level expressions here:
        \* ,_stateNumber |-> _TEPosition
        \* ,_b_stepUnchanged |-> b_step = b_step'
        
        \* Format the `b_step` variable as Json value.
        \* ,_b_stepJson |->
        \*     LET J == INSTANCE Json
        \*     IN J!ToJson(b_step)
        
        \* Lastly, you may build expressions over arbitrary sets of states by
        \* leveraging the _TETrace operator.  For example, this is how to
        \* count the number of times a spec variable changed up to the current
        \* state in the trace.
        \* ,_b_stepModCount |->
        \*     LET F[s \in DOMAIN _TETrace] ==
        \*         IF s = 1 THEN 0
        \*         ELSE IF _TETrace[s].b_step # _TETrace[s-1].b_step
        \*             THEN 1 + F[s-1] ELSE F[s-1]
        \*     IN F[_TEPosition - 1]
    ]

=============================================================================



Parsing and semantic processing can take forever if the trace below is long.
 In this case, it is advised to uncomment the module below to deserialize the
 trace from a generated binary file.

\*
\*---- MODULE TransferNonAtomic_TETrace ----
\*EXTENDS IOUtils, TransferNonAtomic, TLC
\*
\*trace == IODeserialize("TransferNonAtomic_TTrace_1782539810.bin", TRUE)
\*
\*=============================================================================
\*

---- MODULE TransferNonAtomic_TETrace ----
EXTENDS TransferNonAtomic, TLC

trace == 
    <<
    ([b_step |-> "idle",bob |-> 100,alice |-> 100,a_step |-> "idle"]),
    ([b_step |-> "idle",bob |-> 100,alice |-> 70,a_step |-> "credited"])
    >>
----


=============================================================================

---- CONFIG TransferNonAtomic_TTrace_1782539810 ----
CONSTANTS
    AMOUNT_A = 30
    AMOUNT_B = 40

INVARIANT
    _inv

CHECK_DEADLOCK
    \* CHECK_DEADLOCK off because of PROPERTY or INVARIANT above.
    FALSE

INIT
    _init

NEXT
    _next

CONSTANT
    _TETrace <- _trace

ALIAS
    _expression
=============================================================================
\* Generated on Sat Jun 27 13:56:50 CST 2026