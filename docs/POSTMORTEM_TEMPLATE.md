# Postmortem: {{TITLE}}

Date: {{DATE}} · Mode: {{MODE}} · Drill

Blameless: this describes what the system and the tooling made easy or hard, not what a person should have done.

## Summary

Two or three sentences: what broke, who or what was affected, for how long, and what ended it.

## Impact

- What stopped working, for which sites or devices:
- Data delayed (how much, for how long):
- Data lost (how much; how do you know):
- How a customer or a support engineer would have seen it:

## Timeline (UTC)

| Time | Event |
|---|---|
| {{INJECTED}} | Fault began |
| {{SIGNAL}} | First signal |
| {{ACKED}} | Acknowledged |
| | First hypothesis: |
| | What ruled it out: |
| | Cause identified: |
| {{MITIGATED}} | Mitigated |
| | Fully recovered (backlogs drained): |

Time to detect: {{TTD}} · Time to acknowledge: {{TTA}} · Time to mitigate: {{TTM}}

## Detection

What told you? Was it the right signal, and was it fast enough? If a person reported it before an alert did, which alert should have existed?

## Diagnosis

What you looked at, in order, and what each thing told you. Include the wrong turns: they show where the dashboards, logs or runbooks mislead.

## Root cause

The change or condition that caused it, and why it had this effect. Then ask why again: why was that change possible, and why wasn't it caught before it mattered?

## Mitigation and recovery

What stopped the damage, and what restored normal service. Were they the same action?

## What went well

## What was hard

## Actions

| Action | Kind (prevent / detect / mitigate faster) | Where |
|---|---|---|
| | | |

A good action changes the system: an alert, a validation, a default, a runbook entry. "Be more careful" is not an action.
