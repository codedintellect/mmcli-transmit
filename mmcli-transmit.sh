#!/bin/bash

# EDIT THESE VARIABLES
TELEGRAM_BOT_TOKEN=""
# ID of telegram chat, which is allowed to interact with this script
TELEGRAM_CHAT_ID=""
# 10-digit cellular number of end user
USER_NUMBER=""

log_time () { printf "[$(date +%X)] "; }

# Get the ID of the first modem registered by ModemManager
# Error handling should be done seperately
getModemId () {
  modem=$(mmcli -L -J | jq -r '.["modem-list"][0]')
  modemId="${modem:37}"
}

# Variables for telegram api interaction
TELEGRAM_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Clear telegram update queue
# Any telegram messages received while script was offline will be ignored!
updateId=$(\
  curl -sL -G "${TELEGRAM_URL}/getUpdates?offset=-1&limit=1" \
  | jq -r '.["result"][0]["update_id"]')
if [[ $updateId == "null" ]]; then
  updateId=0
fi

# Variables for MegaFon's internet SMS feature
MEGAFON_URL="https://moscow.megafon.ru/api/sms"

declare -A smsQueue=()
buffer=0

warningEmoji="⚠️"
phoneEmoji="📞"

handleCommand () {
  # Fetch new messages from telegram
  update=$(\
    curl -sL -G "${TELEGRAM_URL}/getUpdates?offset=${updateId}&limit=1" \
    | jq -r '.["result"][0]')

  # If no new messages, skip remaining code
  if [[ $update == "null" ]]; then
    return
  fi

  # Increment latest update, to avoid requesting same thing from
  # telegram multiple times
  updateId=$(jq -r '.["update_id"]' <<< "$update")
  let "updateId++"

  # Verify, that received message is in the correct chat
  chatId=$(jq -r '.["message"]["from"]["id"]' <<< "$update")
  messageId=$(jq -r '.["message"]["message_id"]' <<< "$update")
  if [[ $chatId != $TELEGRAM_CHAT_ID ]]; then
    return
  fi

  # Verify, that received message is properly formatted
  text=$(jq -r '.["message"]["text"]' <<< "$update")
  phoneRegex="P:([0-9]{10})"
  [[ $text =~ $phoneRegex ]]
  # Ignore message as random, since could not determine intended receiver
  if [[ $? != 0 ]]; then
    return
  fi
  phoneNum="${BASH_REMATCH[1]}"
  log_time ; echo "Sending SMS to ${phoneNum}"

  # Get message content and convert to unicode escape codes
  message=$(\
    printf "${text:13}" \
    | iconv -t UTF16LE \
    | od -x -An -v --endian=little \
    | tr -d "\t\n\r" \
    | sed 's/ /\\u/g')
  log_time ; echo "Message length is $(("${#message}" / 6)) characters"

  # Check if cellular provider is annoyed and wants captcha verification
  captchaId=$(\
    curl -sL -G "${MEGAFON_URL}/captcha/get/" \
    | jq -r '.["captchaId"]')
  # Received a captcha challenge
  if [[ $captchaId != "null" ]]; then
    log_time ; echo "Got captcha (ID ${captchaId})"

    # Download captcha image
    curl -sL -G "${MEGAFON_URL}/captcha/${captchaId}.png" \
      --output /tmp/captcha.png
    log_time ; echo "Saved captcha to /tmp/captcha.png"

    # Adjust captchas aspect ratio,
    # otherwise the telegram client will inconveniently crop it
    convert /tmp/captcha.png \
      -resize 220x80 \
      -background grey \
      -gravity center \
      -extent 220x80 \
      /tmp/captcha.png

    # Send captcha challenge to telegram
    captchaMsg=$(\
      curl -sL "${TELEGRAM_URL}/sendPhoto?chat_id=${TELEGRAM_CHAT_ID}" \
      -X POST -F "photo=@/tmp/captcha.png" \
      | jq -r '.["result"]["message_id"]')
    log_time ; echo "Forwarded captcha to Telegram"

    # Remove captcha challenge from local storage
    rm -f /tmp/captcha.png

    # Allow 30 seconds to receive a solution
    for i in {1..30}; do
      sleep 1

      # Get latest message
      latestUpdate=$(\
        curl -sL -G "${TELEGRAM_URL}/getUpdates?offset=-1&limit=1" \
        | jq -r '.["result"][0]')
      text=$(\
        jq -r '.["message"]["text"]' <<< "$latestUpdate" \
        | tr '[:upper:]' '[:lower:]')
      msgId=$(jq -r '.["message"]["message_id"]' <<< "$latestUpdate")

      # If message consists of 6 characters, assume it is captcha solution
      if [[ ${#text} == 6 ]]; then
        captchaCode="${text}"
        log_time ; echo "Got captcha decypher - ${captchaCode}"
        # Remove captcha challenge and solution from telegram
        curl -sL -G "${TELEGRAM_URL}/deleteMessage" \
          -d "chat_id=${TELEGRAM_CHAT_ID}" \
          -d "message_id=${captchaMsg}" \
          > /dev/null
        curl -sL -G "${TELEGRAM_URL}/deleteMessage" \
          -d "chat_id=${TELEGRAM_CHAT_ID}" \
          -d "message_id=${msgId}" \
          > /dev/null
        break
      fi
    done
    # Inform end user, that they failed to solve the captcha in time
    if [[ $captchaCode == "" ]]; then
      curl -sL -G "${TELEGRAM_URL}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=Captcha%20timed%20out" \
        > /dev/null
      return
    fi
    captchaData=",\
      \"captcha_id\":\"${captchaId}\",
      \"captcha_code\":\"${captchaCode}\"
    "
  fi

  # Ask cellular provider to generate SMS
  request=$(\
    curl -sL -w '\n' --cookie-jar - "${MEGAFON_URL}/create/" \
    -X POST -H 'Content-Type: application/json' \
    --data-raw $"{
      \"sender\":\"${USER_NUMBER}\",
      \"recipient\":\"${phoneNum}\",
      \"message\":\"${message}\u000a\u002a\"
      ${captchaData}
    }")

  # Catch-All for API errors
  jsonRegex="[{].*[}]"
  [[ $request =~ $jsonRegex ]]
  error=$(jq -r '.["error"]' <<< "${BASH_REMATCH[0]}")
  if [[ "${error}" != "null" ]]; then
    log_time ; echo "ERROR: ${error}"
    curl -sL -G "${TELEGRAM_URL}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "parse_mode=HTML" \
      -d "text=$(jq -sRr @uri <<< "${warningEmoji} $<b>{error}</b>")" \
      > /dev/null
    return
  fi

  # Isolate the UUID of generated SMS from set-cookie header
  # This will be used later to confirm ownership of number
  cookieRegex="[0-9a-f]{8}.[0-9a-f]{4}.[0-9a-f]{4}.[0-9a-f]{4}.[0-9a-f]{12}"
  [[ $request =~ $cookieRegex ]]
  INTERNET_SMS_ID="${BASH_REMATCH[0]}"

  # Create a message for SMS status information
  statusSMS=$(\
    curl -sL -G "${TELEGRAM_URL}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "reply_to_message_id=${messageId}" \
    -d "parse_mode=HTML" \
    -d "text=${INTERNET_SMS_ID}" \
    | jq -r '.["result"]["message_id"]')
  # Append generated SMS to list of monitored outgoing SMS
  smsQueue[$INTERNET_SMS_ID]=$statusSMS
}

handleCode () {
  log_time ; echo "Got code ${1}. Applying..."

  # Send verification code to cellular provider
  curl -sL "${MEGAFON_URL}/confirm/" \
    -X POST -H 'Content-Type: application/json' \
    --data-raw $"{\"code\":\"${1}\"}" \
    --cookie "sms_id=${INTERNET_SMS_ID}" \
    > /dev/null

  # No SMS requires further verification
  unset INTERNET_SMS_ID
}

handleStatus () {
  # Do for every yet to be delivered SMS in queue
  for smsId in "${!smsQueue[@]}"; do
    # Prettify SMS status message
    status=$(\
      curl -sL -G "${MEGAFON_URL}/checkStatus" --cookie "sms_id=${smsId}" \
      | jq -r '.["status"]')
    formatTime () { TZ="Europe/Moscow" date "${1}"; }
    message=$(printf "%b" \
      "Status: ${status}\n" \
      "<i><b>Time:</b> $(formatTime '+%X (%Z)')</i>\n" \
      "<i>$(formatTime '+%A, %B %d')</i>\n" \
      "<b><i>${smsId}</i></b>" \
      | jq -sRr @uri)

    # Send prettified status message to telegram chat
    curl -sL -G "${TELEGRAM_URL}/editMessageText" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "message_id=${smsQueue[$smsId]}" \
      -d "parse_mode=HTML" \
      -d "text=${message}" \
      > /dev/null

    # Since the SMS has been delivered, we do not expect further updates,
    # so we can stop monitoring it
    if [[ "$status" == "DELIVERED" ]]; then
      unset smsQueue[$smsId]
    fi
  done
}

while true; do
  getModemId

  # ModemManager returns no modems
  if [[ $modemId == "" ]]; then
    log_time ; echo "Lost modem. Resetting..."
    systemctl restart ModemManager
    while [[ "${modemId}" == "" ]]; do
      sleep 1
      getModemId
    done
    log_time ; echo "Found modem with id #${modemId}"
  fi

  # Start modem if disabled
  state=$(\
    mmcli -m $modemId -J \
    | jq -r '.["modem"]["generic"]["state"]')
  if [[ $state == "disabled" ]]; then
    mmcli -m $modemId -e > /dev/null
  fi

  packetService=$(\
    mmcli -m $modemId -J \
    | jq -r '.["modem"]["3gpp"]["packet-service-state"]')
  # Restart modem on failure
  if [[ $packetService == "detached" ]]; then
    mmcli -m $modemId -d > /dev/null
    sleep 1
    mmcli -m $modemId -e > /dev/null
  fi

  # Analyze new messages
  for sms in `mmcli -m $modemId --messaging-list-sms`; do
    smsRegex='SMS/([0-9]*)'
    if [[ $sms =~ $smsRegex ]]; then
      smsId=${BASH_REMATCH[1]}
      log_time ; echo "Received new SMS with id #${smsId}"

      number=$(\
        mmcli -m $modemId -s $smsId -J \
        | jq -r '.["sms"]["content"]["number"]')
      message=$(\
        mmcli -m $modemId -s $smsId -J \
        | jq -r '.["sms"]["content"]["text"]')

      # Current SMS contains verification code for queued internet message
      if [[ -n $INTERNET_SMS_ID ]] && [[ $number == "MegaFon_web" ]]; then
        log_time ; echo "Received PIN (${INTERNET_SMS_ID}, ${number})"

        # Pick out 4 digit pin from SMS text
        pinRegex=" ([0-9]{4}) "
        [[ $message =~ $pinRegex ]]
        handleCode "${BASH_REMATCH[1]}"

        # Remove SMS, since it is no longer neaded
        mmcli -m $modemId --messaging-delete-sms $smsId > /dev/null

        # Skip the rest of the SMS handling
        # since end user does not need to see this message
        continue
      fi

      # Converting SMS data into a pretty format for telegram
      timestamp=$(\
        mmcli -m $modemId -s $smsId -J \
        | jq -r '.["sms"]["properties"]["timestamp"]')
      formatTime () { TZ="Europe/Moscow" date -d $timestamp "${1}"; }
      message=$(printf "%b" \
        "${phoneEmoji}  <b>${number}</b>\n\n" \
        "${message}\n\n" \
        "<i><b>Time:</b> $(formatTime '+%X (%Z)')</i>\n" \
        "<i>$(formatTime '+%A, %B %d')</i>" \
        | jq -sRr @uri)

      # Sending prettified SMS to telegram chat
      result=$(\
        curl -sL -G "${TELEGRAM_URL}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=${message}" \
        | jq -r '.["ok"]')
      if [ "$result" = "true" ]; then
        log_time ; echo "Successfully forwarded message to Telegram."
        mmcli -m $modemId --messaging-delete-sms $smsId > /dev/null
      else
        log_time ; echo "Failed to forward message to Telegram."
      fi
    fi
  done

  # Do every tenth loop
  # This part of the code does not require speed, so to conserve
  # resources we only run it occasionally
  if [[ $buffer -eq 10 ]]; then
    buffer=0
    handleCommand
    handleStatus
  fi
  let "buffer++"

  # Add delay between loops
  sleep 1
done
