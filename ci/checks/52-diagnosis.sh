note "diagnosis"
check "doctor runs on the synthetic workspace" "workspace" "$DECK" doctor
check "doctor reports the pack" "all/default" "$DECK" doctor

# ------------------------------------------------ the merge-readiness bundle
# Last, deliberately: the bundle reads what every earlier section produced — a
# gate record, a consultation, a decision a task owns — and it commits into the
# synthetic repositories, which nothing after it should have to work around.
