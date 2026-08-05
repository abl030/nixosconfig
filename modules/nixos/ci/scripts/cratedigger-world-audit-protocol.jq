if (
  (.status == "clean" or .status == "tracked_debt" or .status == "unrecognized_violations")
  and (
    .strict_status == "clean"
    or .strict_status == "integrity_failed"
    or .strict_status == "observations_only"
  )
  and ([.strict_violations, .approved_total, .known_remaining,
        .newly_converged, .converged_total, .new_members,
        .changed_members, .growth] | all(type == "number"))
  and (.state_updated | type) == "boolean"
  and (.by_code | type) == "array"
  and (.by_code | all(
    (.code | type) == "string"
    and ([.approved, .current, .known_remaining,
          .newly_converged, .new_members, .changed_members]
         | all(type == "number"))
  ))
)
then {
  status,
  strict_status,
  strict_violations,
  approved_total,
  known_remaining,
  newly_converged,
  converged_total,
  new_members,
  changed_members,
  growth,
  state_updated,
  by_code
}
else error("invalid tracked world-audit report")
end
