---
status: accepted
---

# Require an end-to-end onboarding check

Onboarding completes only after the user performs one successful Live Dictation into a built-in editable field. The Readiness Check uses the configured global trigger, selected Dictation Microphone, active Model Package, production transcription session, Editing Intent validation, Dictation Mechanics, and ordinary Delivery Route. It cannot call a test-only recognizer, bind transcript text directly to the field, or bypass Accessibility delivery.

After successful delivery, onboarding presents an explicit Finish Setup action and keeps the result visible for confirmation. Only that action records onboarding as complete, attempts to enable Launch at Login, closes the setup window, and transitions VoxKey to its menu-bar posture; the user is not expected to infer completion from or use the window's red close control.

A failure keeps onboarding incomplete and provides content-free, actionable state for permission, audio-device, model, transcription, and delivery problems. The user may retry after correcting the problem, but cannot mark VoxKey Always Ready by skipping the check. The application’s recovery state clears on successful delivery. The built-in destination field keeps the inserted text visible for confirmation, like any other destination editor.

Onboarding exposes one prerequisite action at a time. A custom permission step uses a neutral continuation label and lets the system alert make the actual authorization decision; later permission and model actions appear only after the preceding prerequisite succeeds.
