# venera cli

Command-line tool for loading Venera comic sources and fetching comic data.

## Usage

```sh
venera -v
venera source list
venera source load [-f] <filepath/url>
venera source update [key]
venera source delete <key>

venera <source-key> search [--page n] <keyword>
venera <source-key> info <comic-id>
venera <source-key> pages [--ep id] <comic-id>
venera <source-key> explore [index]
```

Data is stored under `~/.venera` and passed through to `venera_core`.
