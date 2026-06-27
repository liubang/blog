---- MODULE TransferNonAtomic ----
EXTENDS Naturals, TLC

CONSTANTS AMOUNT_A, AMOUNT_B

(*
  Two concurrent transfers, each split into TWO non-atomic steps:
    - A: alice -> bob   (step1: debit alice, step2: credit bob)
    - B: bob -> alice   (step1: debit bob,   step2: credit alice)

  Between step1 and step2, total balance is temporarily broken.
*)

VARIABLES alice, bob, a_step, b_step

vars == << alice, bob, a_step, b_step >>

Init ==
    /\ alice  = 100
    /\ bob    = 100
    /\ a_step = "idle"
    /\ b_step = "idle"

TotalInvariant == alice + bob = 200

(* --- Process A: alice -> bob --- *)

(* Step 1: debit alice *)
A_step1 ==
    /\ a_step = "idle"
    /\ alice >= AMOUNT_A
    /\ alice'  = alice - AMOUNT_A
    /\ bob'    = bob
    /\ a_step' = "credited"
    /\ UNCHANGED b_step

A_step1_skip ==
    /\ a_step = "idle"
    /\ alice < AMOUNT_A
    /\ a_step' = "done"
    /\ UNCHANGED << alice, bob, b_step >>

(* Step 2: credit bob *)
A_step2 ==
    /\ a_step = "credited"
    /\ alice'  = alice
    /\ bob'    = bob + AMOUNT_A
    /\ a_step' = "done"
    /\ UNCHANGED b_step

(* --- Process B: bob -> alice --- *)

(* Step 1: debit bob *)
B_step1 ==
    /\ b_step = "idle"
    /\ bob >= AMOUNT_B
    /\ bob'    = bob - AMOUNT_B
    /\ alice'  = alice
    /\ b_step' = "credited"
    /\ UNCHANGED a_step

B_step1_skip ==
    /\ b_step = "idle"
    /\ bob < AMOUNT_B
    /\ b_step' = "done"
    /\ UNCHANGED << alice, bob, a_step >>

(* Step 2: credit alice *)
B_step2 ==
    /\ b_step = "credited"
    /\ bob'    = bob
    /\ alice'  = alice + AMOUNT_B
    /\ b_step' = "done"
    /\ UNCHANGED a_step

Terminating ==
    /\ a_step = "done"
    /\ b_step = "done"
    /\ UNCHANGED vars

Next ==
    \/ A_step1
    \/ A_step1_skip
    \/ A_step2
    \/ B_step1
    \/ B_step1_skip
    \/ B_step2
    \/ Terminating

Spec == Init /\ [][Next]_vars

====
