# Point-in-time feature guard

The research evaluator must use **availability time**, not just event time. A trade
that occurred at 10:00 but was first received at 10:03 cannot be used in a 10:01
decision, even if a later historical archive contains it.

`autopsyx.research.pit_eval.FeatureAvailability` records the source observation
receive times and the time the feature became ready. Call `validate_at(decision_ts)`
before admitting a feature into an evaluation snapshot. It fails closed when:

- a source became available after the decision;
- feature computation finished after the decision;
- feature readiness precedes the latest source availability;
- timestamps are malformed or source timing is absent.

These checks are an explicit guard utility; they do not automatically instrument
every existing feature pipeline yet. The next integration step is to attach this
metadata to normalized/replayed feature records and enforce it at the decision
boundary. Unit tests establish the guard's behaviour, not strategy performance.
