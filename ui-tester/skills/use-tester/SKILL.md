---
name: use-tester
description: Route any check that needs the computer-use tools — operating an app's GUI by clicking, typing or reading its windows — to the machine's shared Tester session instead of driving the screen from here. Use before the first such check in a session, whether or not this session has the computer-use tools; it covers committing, the test-request format to send the Tester by message, and acting on its per-step verdicts. Also use before starting a test machine for work that is only commands inside it, to ask the Tester for one.
---

# Use the tester

For the rest of this session, a check that needs computer use goes to the machine's Tester session instead of being run here. That means clicking, typing, scrolling or reading an app's windows with the computer-use tools. Only one session can hold the computer-use grant, and two sessions driving the screen at once break each other's runs. So this session, and every subagent it launches, never calls `request_access` or any computer-use tool. A check that needs no computer use stays in this session.

While a request you sent is running, change nothing the run depends on behind the Tester's back: not the app's state, the displays or the windows. A change in the middle of a run can strand it.

Acknowledge in one line that computer-use checks now route to the Tester, then carry on with whatever the user asked.

## Commands inside a test machine

Work that is only commands inside a test machine, over SSH say, needn't wait for a screen run, but starting a machine on your own can collide with one. Ask the Tester for a machine first:

```
Machine request
Reply to: <this session's name, from the first line of ListAgents>
Wants: <the OS and version, or any>
Why no screen: <one line>
```

The Tester names a machine or tells you to wait; its reply arrives as a message. The project's memory says what to do with a machine it names. Tell the Tester as soon as you've given it back. Work that turns out to need the screen, or that measures timing or load, is a test request instead.

Run the app and its command-line tool from your own worktree's build, both of them, and never a copy you find on disk: another session's build may be the one its run is testing, and whatever is on `PATH` belongs to whichever copy installed it.

## Finding the Tester

The Tester is named for its repository: the repository's name (`basename -s .git "$(git remote get-url origin)"`), then ` Tester` — `Acme Tester` for `acme`. Call `ListAgents` and look for the session whose name matches that, ignoring case. If none is listed, tell the user this repository's Tester session isn't running and that one is started with `/ui-tester:become-tester` in a new Claude desktop app session on this repository (the CLI's computer use can't follow display changes). Keep working on anything that doesn't need the live result.

## Sending a request

1. **Commit.** The Tester checks out a commit, not your working tree, so commit everything the test needs; a WIP commit is fine. A worktree of the same repository sees the commit without a push; a separate clone needs it pushed.
2. **Write the plan** so a tester with no context from this session can run it and judge every step:
   - **Setup state:** the environment the check runs in, what must be running or configured before step 1, and the display state when the check depends on it.
     - Steps that click must run on a real display. On macOS's virtual display (every display offline) the Tester can screenshot, hover, scroll and type, but not click. A plan for that state checks by screenshots, typing and scrolling.
     - A check that needs a second Desktop (Space) says so. The Tester adds it on the app's display and removes it afterwards, so it isn't a `USER:` step.
   - **What the plan needs from the user's machine:** which steps need the build installed over the user's copy, and which need the user present. The Tester asks the user before those steps. Mark each step only the user can do `USER:`, whether or not it's a prompt (below): the Tester runs a plan with any such step itself, telling the user before each one, instead of handing it to a subagent.
   - **Prompts:** the Tester never types a credential, so no step carries one. A step that raises a password or admin prompt (sudo without a passwordless rule, an admin dialog, a login screen) is marked as a pause for the user, such as "USER: enter the sudo password at this prompt; wait for them before continuing". Sudo on a machine whose account has passwordless sudo raises no prompt, so it's an ordinary step; the project's memory says which machines have it. A step that tests whether a prompt appears says to cancel it.
   - **Numbered steps**, each one action a person could perform, each with its **expected result** stated as something visible on screen.
   - In many apps, the first click into a window of an app that isn't frontmost only brings the app forward. A step right after another app had the focus (a drag from Finder, say) either expects that or starts with a click that activates the app.
   - A step that checks the app's log asks for lines from the Tester's live `log stream` of the run, not an after-the-fact `log show`, which has no info or debug records. The stream carries only processes whose executable is inside the build under test, helper tools in its bundle included; lines from any other process aren't in it.
   - Nothing that asks the tester to read source, explain a failure, or fix anything. It only observes.
3. **Send** with `SendMessage` to the Tester's name as `ListAgents` prints it, as soon as the check is due, and tell the user it is running. Don't ask the user first whether the screen is free; the user doesn't want that question.

   ```
   Test request
   Reply to: <this session's name, from the first line of ListAgents>
   Branch: <branch>
   Commit: <full SHA>
   Setup: <setup state>
   Steps:
   1. <action> — expect: <visible result>
   2. ...
   ```

The Tester replies with a queue position, then later with pass or fail for each step and screenshots of failures. Replies arrive as messages on their own; don't poll or sleep for them. Tell the user in one line when the request is sent, with its queue position once known. If the Tester asks for something missing, answer it.

## Acting on the verdict

A failed step is a finding about the change. Diagnose it here from the observation and the code, fix it, commit, and send a new request with the new SHA. Rerun the whole plan unless the fix is confined to what one step covers. A step the Tester reports as ambiguous gets its expected result rewritten to something more observable before the rerun; don't resend the same plan.

When anything in a plan would touch something the user wouldn't expect a tester to touch, say so in the plan. The Tester follows the project's policy for it and asks the user otherwise.
