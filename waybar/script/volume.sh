#!/bin/bash

iDIR="$HOME/.config/waybar/icons"

# Get Volume
get_volume() {
	volume=$(pamixer --get-volume)
	echo "$volume"
}

# Get icons
get_icon() {
	current=$(get_volume)
	if [[ "$current" -eq "0" ]]; then
		echo "$iDIR/volume-mute.png"
	elif [[ ("$current" -ge "0") && ("$current" -le "30") ]]; then
		echo "$iDIR/volume-low.png"
	elif [[ ("$current" -ge "30") && ("$current" -le "60") ]]; then
		echo "$iDIR/volume-mid.png"
	elif [[ ("$current" -ge "60") && ("$current" -le "150") ]]; then
		echo "$iDIR/volume-high.png"
	fi
}

# Notify
notify_user() {
	notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$(get_icon)" "Volume : $(get_volume) %"
}

# Increase Volume
inc_volume() {
	# pamixer -i 5 && notify_user
  pactl set-sink-volume @DEFAULT_SINK@ +5% && notify_user
}

# Decrease Volume
dec_volume() {
	# pamixer -d 5 && notify_user
  pactl set-sink-volume @DEFAULT_SINK@ -5% && notify_user
}

toggle_mute() {
	if [ "$(pamixer --get-mute)" == "false" ]; then
		pamixer -m && notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$iDIR/volume-mute.png" "Audio Muted"
	elif [ "$(pamixer --get-mute)" == "true" ]; then
		pamixer -u && notify-send -h string:x-canonical-private-synchronous:sys-notify -u low -i "$(get_icon)" "Audio Unmuted"
	fi
}

# Execute accordingly
if [[ "$1" == "--get" ]]; then
	get_volume
elif [[ "$1" == "--inc" ]]; then
	inc_volume
elif [[ "$1" == "--dec" ]]; then
	dec_volume
else
	get_volume
fi
