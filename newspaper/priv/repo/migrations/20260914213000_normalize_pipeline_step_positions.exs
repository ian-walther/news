defmodule Newspaper.Repo.Migrations.NormalizePipelineStepPositions do
  use Ecto.Migration

  # Step order became canonical (registry-owned); positions are derived from
  # step type, never chosen. Existing data already matches this order, so the
  # update is a guard against drift rather than a data change.
  def up do
    execute """
    UPDATE pipeline_steps
    SET position = CASE step_type
      WHEN 'extraction' THEN 0
      WHEN 'digestion' THEN 1
      ELSE position
    END
    """
  end

  def down, do: :ok
end
