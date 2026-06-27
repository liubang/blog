---- MODULE TransferAtomic ----
EXTENDS Naturals, TLC

CONSTANTS AMOUNT_A, AMOUNT_B

(*
  Two concurrent transfers, each executed atomically:
    - A: alice -> bob, amount AMOUNT_A
    - B: bob -> alice, amount AMOUNT_B

  Each transfer is a single step (debit + credit in one action).
  Invariant: total balance = 200 at all times (should hold).
*)

VARIABLES alice, bob, a_done, b_done

vars == << alice, bob, a_done, b_done >>

Init ==
    /\ alice  = 100
    /\ bob    = 100
    /\ a_done = FALSE
    /\ b_done = FALSE

TotalInvariant == alice + bob = 200

(* A: transfer from alice to bob, one atomic step *)
A_transfer ==
    /\ ~a_done
    /\ alice >= AMOUNT_A
    /\ alice'  = alice - AMOUNT_A
    /\ bob'    = bob   + AMOUNT_A
    /\ a_done' = TRUE
    /\ b_done' = b_done

(* A: insufficient balance, skip *)
A_skip ==
    /\ ~a_done
    /\ alice < AMOUNT_A
    /\ a_done' = TRUE
    /\ UNCHANGED << alice, bob, b_done >>

(* B: transfer from bob to alice, one atomic step *)
B_transfer ==
    /\ ~b_done
    /\ bob >= AMOUNT_B
    /\ bob'    = bob   - AMOUNT_B
    /\ alice'  = alice + AMOUNT_B
    /\ b_done' = TRUE
    /\ a_done' = a_done

B_skip ==
    /\ ~b_done
    /\ bob < AMOUNT_B
    /\ b_done' = TRUE
    /\ UNCHANGED << alice, bob, a_done >>

Terminating ==
    /\ a_done
    /\ b_done
    /\ UNCHANGED vars

Next ==
    \/ A_transfer
    \/ A_skip
    \/ B_transfer
    \/ B_skip
    \/ Terminating

Spec == Init /\ [][Next]_vars

====
