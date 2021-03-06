class EntryDeleter
  include Sidekiq::Worker
  sidekiq_options queue: :worker_slow

  def perform(feed_id)
    if Subscription.where(feed_id: feed_id, active: true).exists?
      feed = Feed.find(feed_id)
      if !feed.protected && feed.subscriptions_count > 0
        delete_entries(feed_id)
      end
    else
      Librato.increment('entry.destroy_skip')
    end
  end

  def delete_entries(feed_id)
    entry_limit = ENV['ENTRY_LIMIT'] ? ENV['ENTRY_LIMIT'].to_i : 500
    entry_count = Entry.where(feed_id: feed_id).count
    if entry_count > entry_limit
      entries_to_keep = Entry.where(feed_id: feed_id).order('published DESC').limit(entry_limit).pluck('entries.id')
      entries_to_delete_ids = Entry.where(feed_id: feed_id, starred_entries_count: 0, recently_played_entries_count: 0).where.not(id: entries_to_keep).pluck(:id)

      # Delete records
      UnreadEntry.where(entry_id: entries_to_delete_ids).delete_all
      UpdatedEntry.where(entry_id: entries_to_delete_ids).delete_all
      RecentlyReadEntry.where(entry_id: entries_to_delete_ids).delete_all
      Entry.where(id: entries_to_delete_ids).delete_all

      if entries_to_delete_ids.present?
        key_created_at = FeedbinUtils.redis_feed_entries_created_at_key(feed_id)
        key_published = FeedbinUtils.redis_feed_entries_published_key(feed_id)
        SearchIndexRemove.perform_async(entries_to_delete_ids)
        $redis[:sorted_entries].with do |redis|
          redis.zrem(key_created_at, entries_to_delete_ids)
          redis.zrem(key_published, entries_to_delete_ids)
        end
      end
      Librato.increment('entry.destroy', by: entries_to_delete_ids.count)
    end
  end

end
