# mmcli-transmit
> BASH service for forwarding SMS received through ModemManager to
> a telegram chat and sending SMS using MegaFon's internet SMS feature.

## Concept
The russian cellular provider "MegaFon" offers a free service for their customers,
to send an SMS from their website to any other customer of "Megafon".

![SMSform](https://github.com/codedintellect/mmcli-transmit/assets/67015559/81ea0aa2-f636-4253-bc06-4d79967e5da1)

By analyzing the web requests this form sends,
I managed to reverse-engineer the API necessary to impliment this feature in a telegram bot.


Utilizing the ModemManager systemd service I can forward incoming SMS to a telegram chat,
and using the MegaFon API I can reply to those messages, if the receiver is on the same network.


The reason I am not using ModemManagers built-in SMS sending command,
is because MegaFon charges its costumers per SMS sent.


> ⚠️ **Nota Bene:**
> 
> MegaFons web services seem to be unavailable outside of the Russian Federation,
> thus requiring a VPN or proxy to access.

## Interesting Points
- Originally I planned to implement a function to split outgoing SMS into chunks of 150 characters,
as shown to be the limit on the webpage. Surprisingly, upon further testing I learnt, that the API
does not check the length of the message, allowing me to send *concatenated SMS*.
- The default mobile interface for Telegram considers the captcha image provided by MegaFon to be too wide
and crops the preview. To combat this I process the image and add padding on the top and bottom as seen below.

![Captcha](https://github.com/codedintellect/mmcli-transmit/assets/67015559/d688a507-58a3-4217-a254-b38b653b75c0)

## Result
Here is an example of me sending an SMS to myself:

![Success](https://github.com/codedintellect/mmcli-transmit/assets/67015559/b5c0c991-1664-4a9d-bfe0-5a0adc29531d)

> ℹ️ Note that "SMS с сайта megafon.ru" is added to the end of any message sent through the API
> and roughly translates to "SMS sent from the website megafon.ru".
