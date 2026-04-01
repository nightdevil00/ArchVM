#!/bin/bash
sudo tee /etc/polkit-1/rules.d/50-udisk2.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF
echo "Done. Log out and back in (or run 'newgrp wheel') for changes to take effect."
