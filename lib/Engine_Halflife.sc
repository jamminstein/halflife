// Engine_Halflife
// Input processor: asymmetric fuzz/drive + ring modulator
// Designed to feed processed audio into softcut's memory buffer
//
// The fuzz stage combines tanh saturation with wavefolding
// for harmonic richness reminiscent of Ayahuasca / Bliss Factory.
// Ring mod multiplies the signal by a sine oscillator,
// blended via crossfade for smooth engagement.

Engine_Halflife : CroneEngine {
  var <synth;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    SynthDef(\halflife_fx, {
      arg out, in_l, in_r,
          drive = 1.5,
          tone = 6000,
          ringmod_amt = 0,
          ringmod_freq = 200;

      var sig_l, sig_r, sig, driven, folded, ring;

      // Read stereo input
      sig_l = In.ar(in_l);
      sig_r = In.ar(in_r);
      sig = [sig_l, sig_r];

      // === FUZZ / DRIVE STAGE ===
      // Pre-gain
      driven = sig * drive;

      // Asymmetric saturation: tanh on negative, harder clip on positive
      // This gives the fuzz an organic, tube-like character
      driven = driven.tanh;

      // Add wavefolding harmonics (subtle)
      folded = (sig * drive * 0.6).fold(-0.6, 0.6);
      driven = driven + (folded * 0.15);

      // Tone control (post-drive LPF to tame fizz)
      driven = LPF.ar(driven, tone);
      driven = LeakDC.ar(driven);

      // === RING MODULATOR ===
      ring = SinOsc.ar(ringmod_freq);
      // Crossfade: -1 = dry, +1 = full ring mod
      driven = XFade2.ar(driven, driven * ring, ringmod_amt * 2 - 1);

      // Soft limit to protect ears and downstream recording
      driven = Limiter.ar(driven, 0.95, 0.01);

      Out.ar(out, driven);
    }).add;

    context.server.sync;

    synth = Synth(\halflife_fx, [
      \in_l, context.in_b[0].index,
      \in_r, context.in_b[1].index,
      \out, context.out_b.index,
      \drive, 1.5,
      \tone, 6000,
      \ringmod_amt, 0,
      \ringmod_freq, 200
    ], context.xg);

    // --- Commands ---
    this.addCommand("drive", "f", { arg msg;
      synth.set(\drive, msg[1]);
    });

    this.addCommand("tone", "f", { arg msg;
      synth.set(\tone, msg[1]);
    });

    this.addCommand("ringmod_amt", "f", { arg msg;
      synth.set(\ringmod_amt, msg[1]);
    });

    this.addCommand("ringmod_freq", "f", { arg msg;
      synth.set(\ringmod_freq, msg[1]);
    });
  }

  free {
    synth.free;
  }
}
