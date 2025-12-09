# frozen_string_literal: true

# name: discourse-translate-system-posts
# about: Enables AI translation for bot and system user posts
# version: 0.8.0
# authors: Jarek
# url: https://github.com/growandwin/discourse-translate-system-posts

after_initialize do
  reloadable_patch do |plugin|
    # Patch PostCandidates - remove user_id > 0 restriction
    DiscourseAi::Translation::PostCandidates.class_eval do
      private_class_method def self.get
        posts =
          Post
            .where("posts.created_at > ?", SiteSetting.ai_translation_backfill_max_age_days.days.ago)
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
    end

    # Patch TopicCandidates - remove user_id > 0 restriction
    DiscourseAi::Translation::TopicCandidates.class_eval do
      private_class_method def self.get
        topics =
          Topic
            .where("topics.created_at > ?", SiteSetting.ai_translation_backfill_max_age_days.days.ago)
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
    end

    # Patch StaticController - use localized content for /privacy, /tos, /faq
    StaticController.class_eval do
      alias_method :original_show, :show

      def show
        map = StaticController::DEFAULT_PAGES.deep_merge(StaticController::CUSTOM_PAGES)
        page = params[:id]
        page = page.gsub(/[^a-z0-9\_\-]/, "")

        if map.has_key?(page) && SiteSetting.content_localization_enabled
          topic_id_setting = map[page][:topic_id]
          if topic_id_setting
            topic = Topic.find_by_id(SiteSetting.get(topic_id_setting))
            if topic
              post = topic.posts.first
              user_locale = I18n.locale.to_s
              
              # Try exact match first, then base locale
              localization = PostLocalization.find_by(post_id: post.id, locale: user_locale)
              localization ||= PostLocalization.find_by(post_id: post.id, locale: user_locale.split("_").first)
              localization ||= PostLocalization.where(post_id: post.id)
                                .where("locale LIKE ?", "#{user_locale.split('_').first}%")
                                .first

              if localization
                original_show
                @body = localization.cooked if @body.present?
                return
              end
            end
          end
        end

        original_show
      end
    end
  end
end