# One repository enrichment cycle (IMPLEMENTATION_PLAN.md §5, §8 step 10). EnrichActorJob's
# twin, and separate rather than one parameterised class because §5 names both and a class
# per queue-visible unit of work is what makes `SELECT class_name, count(*) FROM
# solid_queue_jobs GROUP BY 1` answer a reviewer's question.
#
# It takes no repository id, for the reason EnrichActorJob's comment gives: the entity is
# chosen by §10's fairness policy under a lease, not by the caller.
class EnrichRepositoryJob < ApplicationJob
  def perform
    result = Github::EnrichmentRunner.new.call(entity_class: GithubRepository)

    @outcome = { entity_type: result.entity_type, github_repository_id: result.github_id,
                 enrichment_outcome: result.status }.compact
  end
end
