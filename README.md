<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="Wrenflow icon">
</p>

<h1 align="center">Wrenflow</h1>

<p align="center">
  Open-source speech-to-text for macOS.<br>
  Hold a key, speak, release — text appears at your cursor in ~200ms.
</p>

<p align="center">
  <a href="https://github.com/IlyaGulya/wrenflow/releases/latest/download/Wrenflow.dmg"><b>Download Wrenflow.dmg</b></a><br>
  <sub>macOS 14+ &middot; Apple Silicon + Intel</sub>
</p>

---

Wrenflow is a free and open source alternative to [Wispr Flow](https://wisprflow.ai/), [Superwhisper](https://superwhisper.com/), and [Monologue](https://www.monologue.to/).

1. Download the app from above
2. Press and hold `Fn` anytime to start recording and have whatever you say pasted into the current text field

Transcription runs entirely on your Mac using [Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) via CoreML. No API key required. Nothing leaves your computer.

Optionally, you can enable LLM post-processing for context-aware cleanup — it reads the names of people you're replying to, adapts to your current app, and corrects spelling accordingly. This requires a [Groq](https://groq.com/) API key (free tier available) and is off by default.

There's also a CLI tool (`wrenflow start | stop | toggle | status`) for scripting and automation.

## Build

```bash
make run    # Build and launch
```

## Acknowledgments

Thanks to [Zach Latta](https://github.com/zachlatta) and [FreeFlow](https://github.com/zachlatta/freeflow) — the project that started it all.

## License

MIT
