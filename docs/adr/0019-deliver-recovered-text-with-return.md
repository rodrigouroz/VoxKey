---
status: accepted
---

# Deliver recovered text to a validated recovery destination

When the user deliberately opens the Safety Net, VoxKey captures the text surface that was focused immediately beforehand as a Recovery Destination. It displays a Destination Label containing only the application's icon and display name; it never shows the window title, document name, URL, field label, or surrounding text. Pressing Return performs Recovery Delivery for the Last Result after revalidating that target as an Editing Intent and selecting an ordinary Delivery Route. If no safe target exists, Return remains disabled. Recovery Delivery inserts text only and never sends, submits, or executes a destination action; explicit Command-C copy and dismiss remain secondary recovery choices.
