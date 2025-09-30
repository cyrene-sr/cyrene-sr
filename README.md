# Cyrene-SR
# ![title](screenshot.png)

# Getting started
### Requirements
- [Flat Assembler 1.73](https://flatassembler.net/download.php)
- Linux x86_64 (or [a workaround to emulate linux syscalls on windows](https://git.xeondev.com/xeon/pexecvelf))
- [SDK server](https://git.xeondev.com/reversedrooms/hoyo-sdk)

##### NOTE: this server doesn't include the sdk server as it's not specific per game. You can use `hoyo-sdk` with this server.
#### For additional help, you can join our [discord server](https://discord.xeondev.com)

### Setup
#### Building from sources
a) If you have GNU Make on your machine, just do the following:
```sh
git clone https://git.xeondev.com/cyrene-sr/cyrene-sr.git
cd cyrene-sr
make
```
b) Otherwise, you can invoke FASM manually:
```sh
git clone https://git.xeondev.com/cyrene-sr/cyrene-sr.git
cd cyrene-sr
fasm src/dispatch.asm dispatch
fasm src/gameserver.asm gameserver
```

#### Running the server
a) On Linux, just run 2 executables: `dispatch` and `gameserver`
b) On Windows, use [pexecvelf](https://git.xeondev.com/xeon/pexecvelf) to run the executables.

#### Connecting to server
Currently supported client version is `CNBETAWin3.6.51`, you can get it from 3rd party sources. Next, you have to apply the necessary [client patch](https://git.xeondev.com/cyrene-sr/cyrene-patch). It allows you to connect to the local server and replaces encryption keys with custom ones.

## Support
Your support for this project is greatly appreciated! If you'd like to contribute, feel free to send a tip [via Boosty](https://boosty.to/xeondev/donate)!

## Friendly reminder
This server was implemented for recreational purposes. Right now, it is NOT recommended to run in production environment. Please do not open issues about not implemented features, I'm well aware of this.

