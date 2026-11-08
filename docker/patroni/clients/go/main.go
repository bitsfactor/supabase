// pgx 持续写客户端(pgxpool 默认行为)。环境变量与 node 客户端一致。
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func now() float64 { return float64(time.Now().UnixNano()) / 1e9 }

type fail struct {
	T   float64 `json:"t"`
	Dur float64 `json:"dur"`
	Err string  `json:"err"`
}

func main() {
	name := env("CLIENT_NAME", "go")
	workers, _ := strconv.Atoi(env("WORKERS", "2"))
	intervalMs, _ := strconv.Atoi(env("INTERVAL_MS", "20"))
	gidBase, _ := strconv.Atoi(env("GID_BASE", "3"))
	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?connect_timeout=%s&pool_max_conns=10&statement_timeout=30000",
		env("PGUSER", "supabase_admin"), os.Getenv("PGPASSWORD"), os.Getenv("PGHOST"), env("PGPORT", "5433"), env("PGDATABASE", "postgres"), env("CONNECT_TIMEOUT", "15"))
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		panic(err)
	}
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "30000"
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		panic(err)
	}
	var mu sync.Mutex
	stop := make(chan struct{})
	lastAck := 0.0
	maxGap, maxAttempt := 0.0, 0.0
	ok, failed := 0, 0
	gaps := [][2]float64{}
	fails := []fail{}
	acked := map[int]int{}
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		gid := gidBase + w
		wg.Add(1)
		go func() {
			defer wg.Done()
			n := 0
			for {
				select {
				case <-stop:
					return
				default:
				}
				t0 := now()
				err := func() error {
					ctx := context.Background()
					tx, err := pool.Begin(ctx)
					if err != nil {
						return err
					}
					defer tx.Rollback(ctx)
					if _, err = tx.Exec(ctx, "insert into pt_load (seq, client, ts) values ($1,$2,now()) on conflict do nothing", int64(gid)*1e9+int64(n), name); err != nil {
						return err
					}
					if _, err = tx.Exec(ctx, "select pg_sleep(0.01)", pgx.QueryExecModeSimpleProtocol); err != nil {
						return err
					}
					return tx.Commit(ctx)
				}()
				t1 := now()
				mu.Lock()
				if err == nil {
					g := 0.0
					if lastAck != 0 {
						g = t1 - lastAck
					}
					if g > maxGap {
						maxGap = g
					}
					if g > 1 {
						gaps = append(gaps, [2]float64{lastAck, t1})
					}
					lastAck = t1
					ok++
					n++
					acked[gid] = n
				} else {
					failed++
					if len(fails) < 30 {
						m := err.Error()
						if len(m) > 80 {
							m = m[:80]
						}
						fails = append(fails, fail{t0, t1 - t0, m})
					}
				}
				if t1-t0 > maxAttempt {
					maxAttempt = t1 - t0
				}
				mu.Unlock()
				time.Sleep(time.Duration(intervalMs) * time.Millisecond)
			}
		}()
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	close(stop)
	fin := make(chan struct{})
	go func() { wg.Wait(); close(fin) }()
	select {
	case <-fin:
	case <-time.After(15 * time.Second):
	}
	mu.Lock()
	if tail := now() - lastAck; lastAck != 0 && tail > maxGap {
		maxGap = tail
	}
	out, _ := json.Marshal(map[string]any{"client": name, "ok": ok, "failedAttempts": failed, "maxAckGapS": int(maxGap*100) / 100.0,
		"maxAttemptS": int(maxAttempt*100) / 100.0, "gaps": gaps, "fails": fails, "acked": acked})
	fmt.Println("SUMMARY " + string(out))
	os.Exit(0)
}
