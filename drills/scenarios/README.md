# Sealed scenarios

**Reading these files spoils them.** Each one is a fault `make drill` can apply without telling you which. Run the drills first; read a scenario only after `make drill-reveal` has shown it to you.

Writing a new one: a file `NN.sh` that sets `TITLE` (and `MODES` if it only works in one mode) and defines three functions. `apply` causes the fault, `undo` removes it and must be safe to run when the fault is already gone, and `explain` prints what happened, what it looked like, and how to fix it. The helpers available are at the top of `scripts/drill.sh`. `make drill-selftest` applies and undoes every scenario against a running stack; CI runs it.

Prefer faults that follow a change (a setting, a deploy, a schema or topic edit, a maintenance command) over faults that are simply something switched off. Most real incidents follow a change, and the question "what changed?" is the habit these drills are meant to build.
