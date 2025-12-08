# frozen_string_literal: true

# name: discourse-translate-system-posts
# about: Enables AI translation for bot and system user posts (removes user_id > 0 restriction)
# version: 0.3.0
# authors: Jarek
# url: https://github.com/growandwin/discourse-translate-system-posts

after_initialize do
  
  # Patch 1: PostCandidates - usuwa warunek user_id > 0 dla backfill postow
  if defined?(DiscourseAi::Translation::PostCandidates)
    DiscourseAi::Translation::PostCandidates.class_eval do
      def self.get
        posts =
          Post
            .where(
              "posts.created_at > ?",
              SiteSetting.ai_translation_backfill_max_age_days.days.ago,
            )
            .where(deleted_at: nil)
            .where.not(raw: [nil, ""])
            .where("LENGTH(posts.raw) <= ?", SiteSetting.ai_translation_max_post_length)

        posts = posts.joins(:topic)
        if SiteSetting.ai_translation_backfill_limit_to_public_content
          posts =
            posts
              .where.not(topics: { archetype: Archetype.private_message })
              .where(topics: { category_id: Category.where(read_restricted: false).select(:id) })
        else
          posts =
            posts.where(
              "topics.archetype != ? OR topics.id IN (SELECT topic_id FROM topic_allowed_groups)",
              Archetype.private_message,
            )
        end
      end
      private_class_method :get
    end
  end

  # Patch 2: TopicCandidates - usuwa warunek user_id > 0 dla backfill tematow
  if defined?(DiscourseAi::Translation::TopicCandidates)
    DiscourseAi::Translation::TopicCandidates.class_eval do
      def self.get
        topics =
          Topic
            .where(
              "topics.created_at > ?",
              SiteSetting.ai_translation_backfill_max_age_days.days.ago,
            )
            .where(deleted_at: nil)

        if SiteSetting.ai_translation_backfill_limit_to_public_content
          topics =
            topics
              .where.not(archetype: Archetype.private_message)
              .where(category_id: Category.where(read_restricted: false).select(:id))
        else
          topics =
            topics.where(
              "topics.archetype != ? OR topics.id IN (SELECT topic_id FROM topic_allowed_groups)",
              Archetype.private_message,
            )
        end
      end
      private_class_method :get
    end
  end

end