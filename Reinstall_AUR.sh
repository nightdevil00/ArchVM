for x in $(< pkglist-aur.txt); do yay -S $x --noconfirm; done
