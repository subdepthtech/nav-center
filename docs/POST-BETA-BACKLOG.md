# Post-beta backlog: interview voice and Blast handoff

This work is not part of 0.1.0-beta.1 and is not on the release path. Live voice interviews are not included in 0.1.0-beta.1. Realtime Interview currently creates a local session kit for an external client; it does not start audio or call a model. Nothing here authorizes implementation. The Blast repository path is an open owner input; this repository does not contain or create a Blast repository.

1. Blast ownership and a versioned handoff contract
   Goal: Decide who owns Blast and define a schema-versioned contract for the session kit Nav Center writes today as `interview-realtime-session.json` and the result bundle Blast returns.
   Depends on: Blast repository path and ownership decision.
   Done when: Both repositories have fixtures and documented compatibility rules.

2. Blast import and session shell
   Goal: Validate and load a Nav Center kit, then open a session without audio.
   Depends on: Versioned handoff contract.
   Done when: A valid kit opens and invalid or incompatible kits fail clearly.

3. Microphone and realtime voice runtime
   Goal: Add microphone permission and usage description, audio capture and playback, and a realtime model connection.
   Depends on: Blast session shell and approved outbound-traffic disclosure.
   Done when: API keys stay in the Keychain, never in the workspace, and the new outbound traffic is disclosed.

4. Interview conductor and coaching
   Goal: Run question flow from the kit with follow-ups, timing, and coaching feedback.
   Depends on: Realtime voice runtime and the handoff contract.
   Done when: A synthetic interview produces reviewable coaching feedback.

5. Result bundle and reviewed Nav Center import
   Goal: Blast writes a versioned result bundle; Nav Center imports it into a package only after user review and confirmation.
   Depends on: Versioned result contract and Blast output.
   Done when: Import uses existing confined-write and validation paths and rolls back on failure.

## Open owner inputs

- Blast repository path.
- Ownership decision.
- Target release after 0.1.0-beta.1.
