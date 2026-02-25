## Ralph Loop Workflow
You are running inside a 'ralph loop' headlessly with the -p argument.

!! MESSAGE INBOX !!

Frequently check the folder .msgs/ for files matching *.msg that do
NOT have a corresponding .reply file (use ls or Glob). Do this roughly
once per minute — after each tool call chain or at any natural
pause. For each unread message, read it, then write your reply to
.msgs/{same-name}.reply. Keep replies concise. If the message asks you
to change priorities or stop, follow those instructions. Read the
first prompt from the user (what was provided with -p) and then read
and reply to all unread messages before you start working.

