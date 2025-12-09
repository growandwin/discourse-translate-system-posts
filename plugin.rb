# frozen_string_literal: true

# name: discourse-translate-system-posts
# about: Enables AI translation for bot and system user posts
# version: 0.9.0
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
      private

      def get_localized_static_body(post)
        return nil unless SiteSetting.content_localization_enabled
        
        # Get user locale from: current_user, Accept-Language header, or default
        user_locale = current_user&.locale
        user_locale ||= request.env['HTTP_ACCEPT_LANGUAGE']&.split(',')&.first&.split(';')&.first&.strip&.gsub('-', '_')
        user_locale ||= SiteSetting.default_locale
        
        return nil if user_locale.blank?
        
        base_locale = user_locale.split("_").first
        
        # Try exact match first, then base locale, then any matching base
        localization = PostLocalization.find_by(post_id: post.id, locale: user_locale)
        localization ||= PostLocalization.find_by(post_id: post.id, locale: base_locale)
        localization ||= PostLocalization.where(post_id: post.id).where("locale LIKE ?", "#{base_locale}%").first
        
        localization&.cooked
      end
    end

    StaticController.prepend(Module.new do
      def show
        if params[:id] == "login"
          destination = extract_redirect_param

          if current_user
            return redirect_to(path(destination), allow_other_host: false)
          elsif destination != "/"
            cookies[:destination_url] = path(destination)
          end
        elsif params[:id] == "signup" && current_user
          return redirect_to path("/")
        end

        if SiteSetting.login_required? && current_user.nil? && %w[faq guidelines].include?(params[:id])
          return redirect_to path("/login")
        end

        rename_faq = SiteSetting.experimental_rename_faq_to_guidelines

        if rename_faq
          redirect_paths = %w[/rules /conduct]
          redirect_paths << "/faq" if SiteSetting.faq_url.blank?
          return redirect_to(path("/guidelines")) if redirect_paths.include?(request.path)
        end

        map = StaticController::DEFAULT_PAGES.deep_merge(StaticController::CUSTOM_PAGES)
        @page = params[:id]

        if map.has_key?(@page)
          site_setting_key = map[@page][:redirect]
          url = SiteSetting.get(site_setting_key) if site_setting_key
          return redirect_to(url, allow_other_host: true) if url.present?
        end

        @page = "faq" if @page == "guidelines"
        @page = @page.gsub(/[^a-z0-9\_\-]/, "")

        if map.has_key?(@page)
          topic_id = map[@page][:topic_id]
          topic_id = instance_exec(&topic_id) if topic_id.is_a?(Proc)

          @topic = Topic.find_by_id(SiteSetting.get(topic_id))
          raise Discourse::NotFound unless @topic

          page_name = (@page == "faq") ? (rename_faq ? "guidelines" : "faq") : @page

          title_prefix = I18n.exists?("js.#{page_name}") ? I18n.t("js.#{page_name}") : @topic.title
          @title = "#{title_prefix} - #{SiteSetting.title}"
          
          # Use localized content if available
          post = @topic.posts.first
          @body = get_localized_static_body(post) || post.cooked
          
          @faq_overridden = SiteSetting.faq_url.present?
          @experimental_rename_faq_to_guidelines = rename_faq

          render :show, layout: !request.xhr?, formats: [:html]
          return
        end

        super
      end
    end)
  end
end