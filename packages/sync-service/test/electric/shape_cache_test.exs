defmodule Electric.ShapeCacheTest do
  use ExUnit.Case, async: true

  alias Electric.Replication.Changes
  alias Electric.Replication.Changes.{Relation, Column}
  alias Electric.Replication.LogOffset
  alias Electric.Replication.ShapeLogCollector
  alias Electric.ShapeCache
  alias Electric.ShapeCache.{Storage, ShapeStatus}
  alias Electric.Shapes
  alias Electric.Shapes.Shape

  alias Support.StubInspector
  alias Support.Mock

  import Mox
  import ExUnit.CaptureLog
  import Support.ComponentSetup
  import Support.DbSetup
  import Support.DbStructureSetup
  import Support.TestUtils

  @moduletag :capture_log

  @shape %Shape{
    root_table: {"public", "items"},
    table_info: %{
      {"public", "items"} => %{
        columns: [%{name: "id", type: :text}, %{name: "value", type: :text}],
        pk: ["id"]
      }
    }
  }
  @lsn Electric.Postgres.Lsn.from_integer(13)
  @change_offset LogOffset.new(@lsn, 2)
  @xid 99
  @changes [
    Changes.fill_key(
      %Changes.NewRecord{
        relation: {"public", "items"},
        record: %{"id" => "123", "value" => "Test"},
        log_offset: @change_offset
      },
      ["id"]
    )
  ]

  @zero_offset LogOffset.first()

  @prepare_tables_noop {__MODULE__, :prepare_tables_noop, []}

  @stub_inspector StubInspector.new([
                    %{name: "id", type: "int8", pk_position: 0},
                    %{name: "value", type: "text"}
                  ])

  setup :verify_on_exit!

  setup do
    %{inspector: @stub_inspector}
  end

  describe "get_or_create_shape_handle/2" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_no_pool,
      :with_registry,
      :with_shape_log_collector
    ]

    setup ctx do
      with_shape_cache(
        Map.put(ctx, :inspector, @stub_inspector),
        create_snapshot_fn: fn _, _, _, _, _ -> nil end,
        prepare_tables_fn: @prepare_tables_noop
      )
    end

    test "creates a new shape_handle", %{shape_cache_opts: opts} do
      {shape_handle, @zero_offset} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert is_binary(shape_handle)
    end

    test "returns existing shape_handle", %{shape_cache_opts: opts} do
      {shape_handle1, @zero_offset} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      {shape_handle2, @zero_offset} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert shape_handle1 == shape_handle2
    end
  end

  describe "get_or_create_shape_handle/2 shape initialization" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector
    ]

    test "creates initial snapshot if one doesn't exist", %{storage: storage} = ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, offset} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert offset == @zero_offset
      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)
      Process.sleep(100)
      shape_storage = Storage.for_shape(shape_handle, storage)
      assert Storage.snapshot_started?(shape_storage)
    end

    test "triggers table prep and snapshot creation only once", ctx do
      test_pid = self()

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: fn nil, [{{"public", "items"}, nil}] ->
            send(test_pid, {:called, :prepare_tables_fn})
          end,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            send(test_pid, {:called, :create_snapshot_fn})
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)

      # subsequent calls return the same shape_handle
      for _ <- 1..10,
          do: assert({^shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts))

      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)

      assert_received {:called, :prepare_tables_fn}
      assert_received {:called, :create_snapshot_fn}
      refute_received {:called, _}
    end

    test "triggers table prep and snapshot creation only once even with queued requests", ctx do
      test_pid = self()

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            send(test_pid, {:called, :create_snapshot_fn})
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      link_pid = Process.whereis(opts[:server])

      # suspend the genserver to simulate message queue buildup
      :sys.suspend(link_pid)

      create_call_1 =
        Task.async(fn ->
          {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
          shape_handle
        end)

      create_call_2 =
        Task.async(fn ->
          {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
          shape_handle
        end)

      # resume the genserver and assert both queued tasks return the same shape_handle
      :sys.resume(link_pid)
      shape_handle = Task.await(create_call_1)
      assert shape_handle == Task.await(create_call_2)

      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)

      # any queued calls should still return the existing shape_handle
      # after the snapshot has been created (simulated by directly
      # calling GenServer)
      assert {^shape_handle, _} =
               GenServer.call(link_pid, {:create_or_wait_shape_handle, @shape})

      assert_received {:called, :create_snapshot_fn}
    end

    test "no-ops and warns if snapshot xmin is assigned to unknown shape_handle", ctx do
      shape_handle = "foo"

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop
        )

      shape_meta_table = Access.get(opts, :shape_meta_table)

      log =
        capture_log(fn ->
          GenServer.cast(Process.whereis(opts[:server]), {:snapshot_xmin_known, shape_handle, 10})
          Process.sleep(10)
        end)

      assert log =~
               "Got snapshot information for a #{shape_handle}, that shape handle is no longer valid. Ignoring."

      # should have nothing in the meta table
      assert :ets.next_lookup(shape_meta_table, :_) == :"$end_of_table"
    end
  end

  describe "get_or_create_shape_handle/2 against real db" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_unique_db,
      :with_publication,
      :with_basic_tables,
      :with_inspector,
      :with_shape_log_collector,
      :with_shape_cache
    ]

    setup %{pool: pool} do
      Postgrex.query!(pool, "INSERT INTO items (id, value) VALUES ($1, $2), ($3, $4)", [
        Ecto.UUID.dump!("721ae036-e620-43ee-a3ed-1aa3bb98e661"),
        "test1",
        Ecto.UUID.dump!("721ae036-e620-43ee-a3ed-1aa3bb98e662"),
        "test2"
      ])

      :ok
    end

    test "creates initial snapshot from DB data", %{storage: storage, shape_cache_opts: opts} do
      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)
      storage = Storage.for_shape(shape_handle, storage)
      assert {@zero_offset, stream} = Storage.get_snapshot(storage)

      assert [%{"value" => %{"value" => "test1"}}, %{"value" => %{"value" => "test2"}}] =
               stream_to_list(stream)
    end

    # Set the DB's display settings to something else than Electric.Postgres.display_settings
    @tag database_settings: [
           "DateStyle='Postgres, DMY'",
           "TimeZone='CET'",
           "extra_float_digits=-1",
           "bytea_output='escape'",
           "IntervalStyle='postgres'"
         ]
    @tag additional_fields:
           "date DATE, timestamptz TIMESTAMPTZ, float FLOAT8, bytea BYTEA, interval INTERVAL"
    test "uses correct display settings when querying initial data", %{
      pool: pool,
      storage: storage,
      shape_cache_opts: opts
    } do
      shape =
        update_in(
          @shape.table_info[{"public", "items"}].columns,
          &(&1 ++
              [
                %{name: "date", type: :date},
                %{name: "timestamptz", type: :timestamptz},
                %{name: "float", type: :float8},
                %{name: "bytea", type: :bytea},
                %{name: "interval", type: :interval}
              ])
        )

      Postgrex.query!(
        pool,
        """
        INSERT INTO items (
          id, value, date, timestamptz, float, bytea, interval
        ) VALUES (
          $1, $2, $3, $4, $5, $6, $7
        )
        """,
        [
          Ecto.UUID.bingenerate(),
          "test value",
          ~D[2022-05-17],
          ~U[2022-01-12 00:01:00.00Z],
          1.234567890123456,
          <<0x5, 0x10, 0xFA>>,
          %Postgrex.Interval{
            days: 1,
            months: 0,
            # 12 hours, 59 minutes, 10 seconds
            secs: 46750,
            microsecs: 0
          }
        ]
      )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(shape, opts)
      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)
      storage = Storage.for_shape(shape_handle, storage)
      assert {@zero_offset, stream} = Storage.get_snapshot(storage)

      assert [
               %{"value" => map},
               %{"value" => %{"value" => "test1"}},
               %{"value" => %{"value" => "test2"}}
             ] =
               stream_to_list(stream)

      assert %{
               "date" => "2022-05-17",
               "timestamptz" => "2022-01-12 00:01:00+00",
               "float" => "1.234567890123456",
               "bytea" => "\\x0510fa",
               "interval" => "P1DT12H59M10S"
             } = map
    end

    test "updates latest offset correctly", %{shape_cache_opts: opts, storage: storage} do
      {shape_handle, initial_offset} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)

      assert {^shape_handle, offset_after_snapshot} =
               ShapeCache.get_or_create_shape_handle(@shape, opts)

      expected_offset_after_log_entry =
        LogOffset.new(Electric.Postgres.Lsn.from_integer(1000), 0)

      :ok =
        ShapeCache.update_shape_latest_offset(shape_handle, expected_offset_after_log_entry, opts)

      assert {^shape_handle, offset_after_log_entry} =
               ShapeCache.get_or_create_shape_handle(@shape, opts)

      assert initial_offset == @zero_offset
      assert initial_offset == offset_after_snapshot
      assert offset_after_log_entry > offset_after_snapshot
      assert offset_after_log_entry == expected_offset_after_log_entry

      # Stop snapshot process gracefully to prevent errors being logged in the test
      storage = Storage.for_shape(shape_handle, storage)
      {_, stream} = Storage.get_snapshot(storage)
      Stream.run(stream)
    end

    test "errors if appending to untracked shape_handle", %{shape_cache_opts: opts} do
      shape_handle = "foo"
      log_offset = LogOffset.new(1000, 0)

      {:error, log} =
        with_log(fn -> ShapeCache.update_shape_latest_offset(shape_handle, log_offset, opts) end)

      assert log =~ "Tried to update latest offset for shape #{shape_handle} which doesn't exist"
    end

    test "correctly propagates the error", %{shape_cache_opts: opts} do
      shape = %Shape{root_table: {"public", "nonexistent"}}

      {shape_handle, log} =
        with_log(fn ->
          {shape_handle, _} = ShapeCache.get_or_create_shape_handle(shape, opts)

          assert {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} =
                   ShapeCache.await_snapshot_start(shape_handle, opts)

          shape_handle
        end)

      log =~ "Snapshot creation failed for #{shape_handle}"

      log =~
        ~S|** (Postgrex.Error) ERROR 42P01 (undefined_table) relation "public.nonexistent" does not exist|
    end
  end

  describe "list_shapes/1" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector
    ]

    test "returns empty list initially", ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop
        )

      meta_table = Keyword.fetch!(opts, :shape_meta_table)

      assert ShapeCache.list_shapes(%{shape_meta_table: meta_table}) == []
    end

    test "lists the shape as active once there is a snapshot", ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)
      meta_table = Keyword.fetch!(opts, :shape_meta_table)
      assert [{^shape_handle, @shape}] = ShapeCache.list_shapes(%{shape_meta_table: meta_table})
      assert {:ok, 10} = ShapeStatus.snapshot_xmin(meta_table, shape_handle)
    end

    test "lists the shape even if we don't know xmin", ctx do
      test_pid = self()

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            ref = make_ref()
            send(test_pid, {:waiting_point, ref, self()})
            receive(do: ({:continue, ^ref} -> :ok))
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)

      # Wait until we get to the waiting point in the snapshot
      assert_receive {:waiting_point, ref, pid}

      meta_table = Keyword.fetch!(opts, :shape_meta_table)
      assert [{^shape_handle, @shape}] = ShapeCache.list_shapes(%{shape_meta_table: meta_table})

      send(pid, {:continue, ref})

      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)
      assert [{^shape_handle, @shape}] = ShapeCache.list_shapes(%{shape_meta_table: meta_table})
    end
  end

  describe "has_shape?/2" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector
    ]

    test "returns true for known shape handle", ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _, _, _ ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 100})
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      refute ShapeCache.has_shape?("some-random-id", opts)
      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert ShapeCache.has_shape?(shape_handle, opts)
    end

    test "works with slow snapshot generation", ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _, _, _ ->
            Process.sleep(100)
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 100})
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert ShapeCache.has_shape?(shape_handle, opts)
    end
  end

  describe "await_snapshot_start/4" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector
    ]

    test "returns :started for snapshots that have started", ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _, _, _ ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 100})
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)

      assert ShapeCache.await_snapshot_start(shape_handle, opts) == :started
    end

    test "returns an error if waiting is for an unknown shape handle", ctx do
      shape_handle = "orphaned_handle"

      storage = Storage.for_shape(shape_handle, ctx.storage)

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      assert {:error, :unknown} = ShapeCache.await_snapshot_start(shape_handle, opts)

      refute Storage.snapshot_started?(storage)
    end

    test "handles buffering multiple callers correctly", ctx do
      test_pid = self()

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            ref = make_ref()
            send(test_pid, {:waiting_point, ref, self()})
            receive(do: ({:continue, ^ref} -> :ok))
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})

            # Sometimes only some tasks subscribe before reaching this point, and then hang
            # if we don't actually have a snapshot. This is kind of part of the test, because
            # `await_snapshot_start/3` should always resolve to `:started` in concurrent situations
            GenServer.cast(parent, {:snapshot_started, shape_handle})
            Storage.make_new_snapshot!([[1], [2]], storage)
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)

      storage = Storage.for_shape(shape_handle, ctx.storage)

      tasks =
        for _id <- 1..10 do
          Task.async(fn ->
            assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)
            {_, stream} = Storage.get_snapshot(storage)
            assert Enum.count(stream) == 2
          end)
        end

      assert_receive {:waiting_point, ref, pid}
      send(pid, {:continue, ref})

      Task.await_many(tasks)
    end

    test "errors while streaming from database are sent to all callers", ctx do
      stream_from_database =
        Stream.map(1..5, fn
          5 ->
            raise "some error"

          n ->
            # Sleep to allow read processes to run
            Process.sleep(1)
            [n]
        end)

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            GenServer.cast(parent, {:snapshot_started, shape_handle})

            Storage.make_new_snapshot!(stream_from_database, storage)
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)

      storage = Storage.for_shape(shape_handle, ctx.storage)

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            :started = ShapeCache.await_snapshot_start(shape_handle, opts)
            {_, stream} = Storage.get_snapshot(storage)

            assert_raise RuntimeError, fn -> Stream.run(stream) end
          end)
        end

      Task.await_many(tasks)
    end

    test "propagates error in snapshot creation to listeners", ctx do
      test_pid = self()

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, _storage ->
            ref = make_ref()
            send(test_pid, {:waiting_point, ref, self()})
            receive(do: ({:continue, ^ref} -> :ok))
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})

            GenServer.cast(
              parent,
              {:snapshot_failed, shape_handle, %RuntimeError{message: "expected error"}, []}
            )
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      task = Task.async(fn -> ShapeCache.await_snapshot_start(shape_handle, opts) end)

      log =
        capture_log(fn ->
          assert_receive {:waiting_point, ref, pid}
          send(pid, {:continue, ref})

          assert {:error, %RuntimeError{message: "expected error"}} =
                   Task.await(task)
        end)

      assert log =~ "Snapshot creation failed for #{shape_handle}"
    end
  end

  describe "handle_truncate/2" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector
    ]

    test "cleans up shape data and rotates the shape handle", ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      Process.sleep(50)
      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)

      storage = Storage.for_shape(shape_handle, ctx.storage)

      Storage.append_to_log!(
        changes_to_log_items([
          %Electric.Replication.Changes.NewRecord{
            relation: {"public", "items"},
            record: %{"id" => "1", "value" => "Alice"},
            log_offset: LogOffset.new(Electric.Postgres.Lsn.from_integer(1000), 0)
          }
        ]),
        storage
      )

      assert Storage.snapshot_started?(storage)
      assert Enum.count(Storage.get_log_stream(@zero_offset, storage)) == 1

      ref = ctx.electric_instance_id |> Shapes.Consumer.whereis(shape_handle) |> Process.monitor()

      log = capture_log(fn -> ShapeCache.handle_truncate(shape_handle, opts) end)
      assert log =~ "Truncating and rotating shape handle"

      assert_receive {:DOWN, ^ref, :process, _pid, _}
      # Wait a bit for the async cleanup to complete

      refute Storage.snapshot_started?(storage)
    end
  end

  describe "clean_shape/2" do
    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector
    ]

    test "cleans up shape data and rotates the shape handle", ctx do
      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      Process.sleep(50)
      assert :started = ShapeCache.await_snapshot_start(shape_handle, opts)

      storage = Storage.for_shape(shape_handle, ctx.storage)

      Storage.append_to_log!(
        changes_to_log_items([
          %Electric.Replication.Changes.NewRecord{
            relation: {"public", "items"},
            record: %{"id" => "1", "value" => "Alice"},
            log_offset: LogOffset.new(Electric.Postgres.Lsn.from_integer(1000), 0)
          }
        ]),
        storage
      )

      assert Storage.snapshot_started?(storage)
      assert Enum.count(Storage.get_log_stream(@zero_offset, storage)) == 1

      {module, _} = storage

      ref =
        Process.monitor(
          module.name(ctx.electric_instance_id, shape_handle)
          |> GenServer.whereis()
        )

      log = capture_log(fn -> :ok = ShapeCache.clean_shape(shape_handle, opts) end)
      assert log =~ "Cleaning up shape"

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      assert_raise ArgumentError,
                   ~r"the table identifier does not refer to an existing ETS table",
                   fn -> Stream.run(Storage.get_log_stream(@zero_offset, storage)) end

      assert_raise RuntimeError,
                   ~r"Snapshot no longer available",
                   fn -> Storage.get_snapshot(storage) end

      {shape_handle2, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert shape_handle != shape_handle2
    end

    test "cleans up shape swallows error if no shape to clean up", ctx do
      shape_handle = "foo"

      %{shape_cache_opts: opts} =
        with_shape_cache(Map.merge(ctx, %{pool: nil, inspector: @stub_inspector}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, 10})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      {:ok, _} = with_log(fn -> ShapeCache.clean_shape(shape_handle, opts) end)
    end
  end

  describe "after restart" do
    # Capture the log to hide the GenServer exit messages
    @describetag capture_log: true

    @describetag :tmp_dir
    @snapshot_xmin 10

    setup do
      %{
        # don't crash the log collector when the shape consumers get killed by our tests
        link_log_collector: false,
        inspector: Support.StubInspector.new([%{name: "id", type: "int8", pk_position: 0}])
      }
    end

    setup [
      :with_electric_instance_id,
      :with_cub_db_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector,
      :with_no_pool
    ]

    setup(ctx,
      do:
        with_shape_cache(Map.put(ctx, :inspector, @stub_inspector),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, @snapshot_xmin})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )
    )

    test "restores shape_handles", %{shape_cache_opts: opts} = context do
      {shape_handle1, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      :started = ShapeCache.await_snapshot_start(shape_handle1, opts)
      restart_shape_cache(context)
      {shape_handle2, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      assert shape_handle1 == shape_handle2
    end

    test "restores snapshot xmins", %{shape_cache_opts: opts} = context do
      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      :started = ShapeCache.await_snapshot_start(shape_handle, opts)
      meta_table = Keyword.fetch!(opts, :shape_meta_table)
      [{^shape_handle, @shape}] = ShapeCache.list_shapes(%{shape_meta_table: meta_table})
      {:ok, @snapshot_xmin} = ShapeStatus.snapshot_xmin(meta_table, shape_handle)

      restart_shape_cache(context)
      :started = ShapeCache.await_snapshot_start(shape_handle, opts)

      assert [{^shape_handle, @shape}] = ShapeCache.list_shapes(%{shape_meta_table: meta_table})
      {:ok, @snapshot_xmin} = ShapeStatus.snapshot_xmin(meta_table, shape_handle)
    end

    test "restores latest offset", %{shape_cache_opts: opts} = context do
      offset = @change_offset
      {shape_handle, _} = ShapeCache.get_or_create_shape_handle(@shape, opts)
      :started = ShapeCache.await_snapshot_start(shape_handle, opts)

      ref = Shapes.Consumer.monitor(context.electric_instance_id, shape_handle)

      ShapeLogCollector.store_transaction(
        %Changes.Transaction{
          changes: @changes,
          xid: @xid,
          last_log_offset: @change_offset,
          lsn: @lsn,
          affected_relations: MapSet.new([{"public", "items"}])
        },
        context.shape_log_collector
      )

      assert_receive {Shapes.Consumer, ^ref, @xid}

      {^shape_handle, ^offset} = ShapeCache.get_or_create_shape_handle(@shape, opts)

      # without this sleep, this test becomes unreliable. I think maybe due to
      # delays in actually writing the data to cubdb/fsyncing the tx. I've
      # tried explicit `CubDb.file_sync/1` calls but it doesn't work, the only
      # reliable method is to wait just a little bit...
      Process.sleep(10)

      restart_shape_cache(context)

      :started = ShapeCache.await_snapshot_start(shape_handle, opts)
      assert {^shape_handle, ^offset} = ShapeCache.get_or_create_shape_handle(@shape, opts)
    end

    test "restores relations", ctx do
      %{shape_cache: {_shape_cache, opts}} = ctx

      rel = %Relation{
        id: 42,
        schema: "public",
        table: "items",
        columns: [
          %Column{name: "id", type_oid: 9},
          %Column{name: "value", type_oid: 2}
        ]
      }

      assert :ok = ShapeLogCollector.handle_relation_msg(rel, ctx.shape_log_collector)
      assert {:ok, ^rel} = wait_for_relation(ctx, rel.id)

      assert_receive {Electric.PersistentKV.Memory, {:set, _, _}}

      restart_shape_cache(ctx)

      assert {:ok, ^rel} = wait_for_relation(ctx, rel.id, 2_000)
      assert ^rel = ShapeCache.get_relation(rel.id, opts)
    end

    defp restart_shape_cache(context) do
      stop_shape_cache(context)
      # Wait 1 millisecond to ensure shape handles are not generated the same
      Process.sleep(1)
      with_cub_db_storage(context)

      with_shape_cache(Map.put(context, :inspector, @stub_inspector),
        prepare_tables_fn: @prepare_tables_noop,
        create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
          GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, @snapshot_xmin})
          Storage.make_new_snapshot!([["test"]], storage)
          GenServer.cast(parent, {:snapshot_started, shape_handle})
        end
      )
    end

    defp stop_shape_cache(ctx) do
      %{shape_cache: {shape_cache, shape_cache_opts}} = ctx

      consumers =
        for {shape_handle, _} <- shape_cache.list_shapes(Map.new(shape_cache_opts)) do
          pid = Shapes.Consumer.whereis(ctx.electric_instance_id, shape_handle)
          {pid, Process.monitor(pid)}
        end

      Shapes.ConsumerSupervisor.stop_all_consumers(ctx.consumer_supervisor)

      for {pid, ref} <- consumers do
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end

      stop_processes([shape_cache_opts[:server], ctx.consumer_supervisor])
    end

    defp stop_processes(process_names) do
      processes =
        for name <- process_names, pid = Process.whereis(name) do
          Process.unlink(pid)
          Process.monitor(pid)
          Process.exit(pid, :kill)
          {pid, name}
        end

      for {pid, name} <- processes do
        receive do
          {:DOWN, _, :process, ^pid, :killed} -> :process_killed
        after
          500 -> raise "#{name} process not killed"
        end
      end
    end
  end

  describe "relation handling" do
    @describetag capture_log: true

    @describetag :tmp_dir
    @snapshot_xmin 10

    setup [
      :with_electric_instance_id,
      :with_in_memory_storage,
      :with_persistent_kv,
      :with_log_chunking,
      :with_registry,
      :with_shape_log_collector,
      :with_no_pool
    ]

    setup(ctx) do
      ctx =
        with_shape_cache(
          Map.merge(ctx, %{inspector: {Mock.Inspector, []}}),
          prepare_tables_fn: @prepare_tables_noop,
          create_snapshot_fn: fn parent, shape_handle, _shape, _, storage ->
            GenServer.cast(parent, {:snapshot_xmin_known, shape_handle, @snapshot_xmin})
            Storage.make_new_snapshot!([["test"]], storage)
            GenServer.cast(parent, {:snapshot_started, shape_handle})
          end
        )

      ctx
    end

    defp monitor_consumer(electric_instance_id, shape_handle) do
      electric_instance_id |> Shapes.Consumer.whereis(shape_handle) |> Process.monitor()
    end

    defp shapes do
      shape1 =
        Shape.new!("public.test_table",
          inspector: StubInspector.new([%{name: "id", type: "int8", pk_position: 0}])
        )

      shape2 =
        Shape.new!("public.test_table",
          inspector: StubInspector.new([%{name: "id", type: "int8", pk_position: 0}]),
          where: "id > 5"
        )

      shape3 =
        Shape.new!("public.other_table",
          inspector: StubInspector.new([%{name: "id", type: "int8", pk_position: 0}])
        )

      [shape1, shape2, shape3]
    end

    defp start_shapes(%{
           shape_cache: {shape_cache, opts},
           electric_instance_id: electric_instance_id
         }) do
      [shape1, shape2, shape3] = shapes()

      {shape_handle1, _} = shape_cache.get_or_create_shape_handle(shape1, opts)
      {shape_handle2, _} = shape_cache.get_or_create_shape_handle(shape2, opts)
      {shape_handle3, _} = shape_cache.get_or_create_shape_handle(shape3, opts)

      :started = shape_cache.await_snapshot_start(shape_handle1, opts)
      :started = shape_cache.await_snapshot_start(shape_handle2, opts)
      :started = shape_cache.await_snapshot_start(shape_handle3, opts)

      ref1 = monitor_consumer(electric_instance_id, shape_handle1)
      ref2 = monitor_consumer(electric_instance_id, shape_handle2)
      ref3 = monitor_consumer(electric_instance_id, shape_handle3)

      [
        {shape_handle1, ref1},
        {shape_handle2, ref2},
        {shape_handle3, ref3}
      ]
    end

    test "stores relation if it is not known", ctx do
      %{shape_cache: {_shape_cache, opts}} = ctx

      relation_id = "rel1"

      rel = %Relation{
        id: relation_id,
        schema: "public",
        table: "test_table",
        columns: []
      }

      Mock.Inspector
      |> expect(:clean_column_info, 1, fn {"public", "test_table"}, _ -> true end)
      |> allow(self(), opts[:server])

      assert :ok = ShapeLogCollector.handle_relation_msg(rel, ctx.shape_log_collector)

      assert {:ok, ^rel} = wait_for_relation(ctx, relation_id)
    end

    test "does not clean shapes if relation didn't change", ctx do
      %{shape_cache: {shape_cache, opts}} = ctx

      relation_id = "rel1"

      shape =
        Shape.new!("public.test_table",
          inspector: StubInspector.new([%{name: "id", type: :int8}])
        )

      {shape_handle, _} = shape_cache.get_or_create_shape_handle(shape, opts)

      ref = monitor_consumer(ctx.electric_instance_id, shape_handle)

      rel = %Relation{
        id: relation_id,
        schema: "public",
        table: "test_table",
        columns: []
      }

      Mock.Inspector
      |> expect(:clean_column_info, 1, fn _, _ -> true end)
      |> allow(self(), opts[:server])

      assert :ok = ShapeLogCollector.handle_relation_msg(rel, ctx.shape_log_collector)

      Mock.Inspector
      |> expect(:clean_column_info, 0, fn _, _ -> true end)
      |> allow(self(), opts[:server])

      assert :ok = ShapeLogCollector.handle_relation_msg(rel, ctx.shape_log_collector)

      refute_receive {:DOWN, ^ref, :process, _, _}
    end

    test "cleans inspector cache for new relations", ctx do
      %{shape_cache: {_shape_cache, opts}} = ctx

      relation_id = "rel1"

      [
        {_shape_handle1, _ref1},
        {_shape_handle2, _ref2},
        {_shape_handle3, _ref3}
      ] = start_shapes(ctx)

      rel = %Relation{
        id: relation_id,
        schema: "public",
        table: "test_table",
        columns: []
      }

      Mock.Inspector
      |> expect(:clean_column_info, 1, fn {"public", "test_table"}, _ -> true end)
      |> allow(self(), opts[:server])

      assert :ok = ShapeLogCollector.handle_relation_msg(rel, ctx.shape_log_collector)
    end

    test "cleans shapes affected by table renaming and logs a warning", ctx do
      %{shape_cache: {_shape_cache, opts}} = ctx

      relation_id = "rel1"

      [
        {_shape_handle1, ref1},
        {_shape_handle2, ref2},
        {_shape_handle3, ref3}
      ] = start_shapes(ctx)

      old_rel = %Relation{
        id: relation_id,
        schema: "public",
        table: "test_table",
        columns: []
      }

      new_rel = %Relation{
        id: relation_id,
        schema: "public",
        table: "renamed_test_table",
        columns: []
      }

      Mock.Inspector
      |> expect(:clean_column_info, 1, fn {"public", "test_table"}, _ -> true end)
      |> allow(self(), opts[:server])

      assert :ok = ShapeLogCollector.handle_relation_msg(old_rel, ctx.shape_log_collector)

      Mock.Inspector
      |> expect(:clean_column_info, 1, fn {"public", "test_table"}, _ -> true end)
      |> allow(self(), opts[:server])

      log =
        capture_log(fn ->
          assert :ok = ShapeLogCollector.handle_relation_msg(new_rel, ctx.shape_log_collector)
          assert_receive {:DOWN, ^ref1, :process, _, _}
          assert_receive {:DOWN, ^ref2, :process, _, _}
          refute_receive {:DOWN, ^ref3, :process, _, _}
        end)

      assert log =~ "Schema for the table public.test_table changed"
    end

    test "cleans shapes affected by a relation change", ctx do
      %{shape_cache: {_shape_cache, opts}} = ctx

      relation_id = "rel1"

      [
        {_shape_handle1, ref1},
        {_shape_handle2, ref2},
        {_shape_handle3, ref3}
      ] = start_shapes(ctx)

      old_rel = %Relation{
        id: relation_id,
        schema: "public",
        table: "test_table",
        columns: [%Column{name: "id", type_oid: 901}]
      }

      new_rel = %Relation{
        id: relation_id,
        schema: "public",
        table: "test_table",
        columns: [%Column{name: "id", type_oid: 123}]
      }

      Mock.Inspector
      |> expect(:clean_column_info, 1, fn {"public", "test_table"}, _ -> true end)
      |> allow(self(), opts[:server])

      assert :ok = ShapeLogCollector.handle_relation_msg(old_rel, ctx.shape_log_collector)

      Mock.Inspector
      |> expect(:clean_column_info, 1, fn {"public", "test_table"}, _ -> true end)
      |> allow(self(), opts[:server])

      log =
        capture_log(fn ->
          assert :ok = ShapeLogCollector.handle_relation_msg(new_rel, ctx.shape_log_collector)
          assert_receive {:DOWN, ^ref1, :process, _, _}
          assert_receive {:DOWN, ^ref2, :process, _, _}
          refute_receive {:DOWN, ^ref3, :process, _, _}
        end)

      assert log =~ "Schema for the table public.test_table changed"
    end
  end

  def prepare_tables_noop(_, _), do: :ok

  defp stream_to_list(stream) do
    stream
    |> Enum.map(&Jason.decode!/1)
    |> Enum.sort_by(fn %{"value" => %{"value" => val}} -> val end)
  end

  defp wait_for_relation(ctx, relation_id, timeout \\ 1_000) do
    parent = self()

    Task.start(fn ->
      do_wait_for_relation(ctx.shape_cache, relation_id, parent)
    end)

    receive do
      {:relation, ^relation_id, relation} -> {:ok, relation}
    after
      timeout -> flunk("timed out waiting for relation #{inspect(relation_id)}")
    end
  end

  defp do_wait_for_relation({shape_cache, shape_cache_opts}, relation_id, parent) do
    if relation = shape_cache.get_relation(relation_id, shape_cache_opts) do
      send(parent, {:relation, relation_id, relation})
    else
      Process.sleep(10)
      do_wait_for_relation({shape_cache, shape_cache_opts}, relation_id, parent)
    end
  end
end
