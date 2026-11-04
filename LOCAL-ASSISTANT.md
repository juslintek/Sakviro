# Parrot Assistant

The separate local build keeps its own app data and does not update from the upstream Parrot feed. Build it with:

```sh
make BUNDLE_ID=com.linas.parrot.assistant DISPLAY_NAME='Parrot Assistant' VERSION=0.29.7-assistant1 SIGN_IDENTITY=-
```

Copy the resulting `dist/Parrot.app` to a separate app name. Ad-hoc signatures change on rebuild, so macOS may request microphone, system-audio and screen access again. Keep the original app and its data separate.

In Settings → Transcription, choose an MLX model, the Python executable with `mlx-whisper`, and its local model folder. Automatic language detection works with the Lithuanian and English model choices; a specific language can also be selected. Model quality depends on the recording and model. The companion `../SETUP.md` lists this Mac's installed paths.

In Settings → Assistant, select a CLI provider. Cloud CLI providers send meeting text to the selected account's service; they do not send audio. Sign in through that CLI first. On-device only blocks cloud providers. The app does not read project folders until documents are added to its Knowledge Base. Use the call brief to name the project when its context matters.

macOS has no Lithuanian contextual embedding on the tested machine, so Lithuanian documents rely on lexical matching. A synthetic project document was retrieved using its project name in the brief and a paraphrased question; this does not establish retrieval for every paraphrase.

Video recording requires choosing a window or display at the start of each recording. If adding audio to the video fails, the saved raw video can be retried from the meeting. Imported MLX audio longer than 30 seconds is split at quiet boundaries; if none is found, split the file at a pause and retry.
